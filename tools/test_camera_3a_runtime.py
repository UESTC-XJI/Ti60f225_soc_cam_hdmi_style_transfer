"""Call the actual RV32 ELF 3A service against injected frames and bus faults.

Uses the same checked BSP I2C path as the board. The plant scenarios are
independent of the control formula; assertions cover observable transactions,
settling guards, gains, safety bounds and fault behavior.
"""
from pathlib import Path
import ctypes as C
import json
import re
from test_firmware_runtime import Machine, SYMBOLS, ROOT
from unicorn import UC_HOOK_CODE
from unicorn.riscv_const import UC_RISCV_REG_RA, UC_RISCV_REG_A0, UC_RISCV_REG_A1, UC_RISCV_REG_A2, UC_RISCV_REG_A3, UC_RISCV_REG_SP, UC_RISCV_REG_GP, UC_RISCV_REG_PC

class State(C.LittleEndianStructure):
    # Derive field order from the public C ABI, with RV32's uint64 alignment.
    pass
header=(ROOT/'software/firmware/camera_3a.h').read_text()
body=re.search(r'typedef struct \{(.*?)\} camera_3a_t;',header,re.S)[1]
State._fields_=[(name.strip(),C.c_uint64 if kind=='uint64_t' else C.c_uint32)
               for kind,names in re.findall(r'(uint32_t|uint64_t)\s+([^;]+);',body)
               for name in names.split(',')]

class ControlMachine(Machine):
    def __init__(self, failure=None, readback_delay=0):
        self.regs={0:0x4f534431,0x34:0x20000,0x38:0x1bf,0xec:1,
                   0x60:0x168,0x64:256,0x68:0x1a9,0x58:0,0x54:0}
        self.failure=failure
        self.hold=False
        self.fail_reg=None
        self.last_tx_write=False
        self.no_stats=False
        self.sequence_reads=0
        self.readback_delay=readback_delay
        self.held_registers={};self.latch_frame=None;self.injected_frame=0
        super().__init__('3a')
        self.sensor.update({0x320e:0x0e,0x320f:0x10,0x3e00:0xa1,0x3e01:0xbb,0x3e02:0xf7})
        self.uc.reg_write(UC_RISCV_REG_SP,SYMBOLS['_sp'])
        self.uc.reg_write(UC_RISCV_REG_GP,SYMBOLS['__global_pointer$'])
        self.uc.mem_write(0x100,b'\x13\x00\x00\x00')
        self.uc.mem_write(SYMBOLS['app_awb_mode'],(1).to_bytes(4,'little'))
        self.now=100000000

    def call(self,name,*args):
        for reg,val in zip([UC_RISCV_REG_A0,UC_RISCV_REG_A1,UC_RISCV_REG_A2,UC_RISCV_REG_A3],args):
            self.uc.reg_write(reg,val)
        self.uc.reg_write(UC_RISCV_REG_RA,0x100)
        try:self.uc.emu_start(SYMBOLS[name],0x104,count=2000000)
        except Exception:
            print('exception in',name,'PC',hex(self.uc.reg_read(UC_RISCV_REG_PC)))
            raise
        result=self.uc.reg_read(UC_RISCV_REG_A0)
        return result if result<0x80000000 else result-0x100000000

    def init(self):
        return self.call('camera_3a_init',SYMBOLS['app_3a'],self.now,0)

    def state(self):
        return State.from_buffer_copy(bytes(self.uc.mem_read(SYMBOLS['app_3a'],C.sizeof(State))))

    def service(self,ms=1):
        self.now+=ms*100000
        self.call('camera_3a_service',SYMBOLS['app_3a'],self.now&0xffffffff,self.now>>32)

    def i2c_read(self,uc,off,size,data):
        if off==4 and self.failure=='timeout':return 0x100
        if off==0x40 and self.failure=='start_dropped':return 1<<9
        if off==0x40 and self.failure=='stop_dropped':return 1<<10
        if off==0xc and self.failure=='missing_ack_valid':return 0
        return super().i2c_read(uc,off,size,data)

    def i2c_ack_result(self):
        if self.failure=='nack' or (self.fail_reg==self.i2c_ptr and self.last_tx_write):return 1
        return super().i2c_ack_result()

    def i2c_write(self,uc,off,size,value,data):
        if off==0:self.last_tx_write=self.i2c_phase=='write'
        before=len(self.camera_writes)
        old_sensor=self.sensor.copy() if self.failure=='ignore_exposure' else None
        held_sensor=self.sensor.copy() if self.readback_delay else None
        super().i2c_write(uc,off,size,value,data)
        if old_sensor is not None and len(self.camera_writes)>before and self.i2c_ptr==0x3e01:
            self.sensor[0x3e01]=old_sensor[0x3e01]
        if held_sensor is not None and self.hold and len(self.camera_writes)>before and self.i2c_ptr in (0x3e00,0x3e01,0x3e02):
            self.held_registers[self.i2c_ptr]=self.sensor[self.i2c_ptr]
            self.sensor[self.i2c_ptr]=held_sensor[self.i2c_ptr]
        if len(self.camera_writes)>before and self.camera_writes[-1][0]==0x3812:
            self.hold=self.camera_writes[-1][1]==0
            if not self.hold and self.held_registers:self.latch_frame=self.injected_frame+self.readback_delay

    def osd_read(self,uc,off,size,data):
        if off==0xc0 and self.failure=='tearing':
            self.regs[off]=self.regs.get(off,0)+1
        return self.regs.get(off,0)

    def osd_write(self,uc,off,size,value,data):
        self.regs[off]=value
        if off==0x50:
            # bit1 = display APPLY (QSE view/label); the HDMI side is not modeled, so it completes at once.
            if value==2:return
            assert value==1 and not self.regs.get(0x54,0)
            self.regs[0x54]=1

    def ack_gain(self):
        for shadow,active in [(0x40,0x60),(0x44,0x64),(0x48,0x68)]:
            self.regs[active]=self.regs[shadow]
        self.regs[0x58]=(self.regs[0x58]+1)&0xffffffff
        self.regs[0x54]=0

    def frame(self,frame,mean=96,hot=0,r=40,g=100,b=50,cells=1000,cfg=None,seq=None):
        self.injected_frame=frame
        if self.latch_frame is not None and frame>=self.latch_frame:
            self.sensor.update(self.held_registers);self.held_registers={};self.latch_frame=None
        cfg=self.regs[0x58] if cfg is None else cfg
        self.regs.update({0xc0:frame if seq is None else seq,0xc4:mean*1000,0xe4:1000,0xe8:hot,
                          0xd0:1|(16 if cells else 0),0xd8:frame&0xffffffff,0xdc:cfg,
                          0xe0:frame&0xffffffff,0x180:r*cells,0x184:2*g*cells,
                          0x188:b*cells,0x18c:cells,0x1a0:1000,0xc8:self.now&0xffffffff,0xcc:self.now>>32})

results=[]
# Exposure: bright -> decreasing, bounded writes only on a NEW CSI start.
m=ControlMachine();assert m.init()==0
assert m.state().vts==3600 and m.state().maximum==7189 and m.state().exposure==7103
m.frame(1,200);m.service();assert m.state().queued_exposure and not m.camera_writes
m.service();assert not m.camera_writes
m.regs[0xe0]=2;m.service();s=m.state();assert s.ae_updates==0 and s.exposure==7103 and 4<=s.pending_exposure<7103
assert m.camera_writes[0]==(0x3812,0) and m.camera_writes[-1]==(0x3812,0x30)
assert m.sensor[0x3e00]&0xf0==0xa0 and m.sensor[0x3e02]&15==7 and not m.hold
for f in (2,3,4):
    m.frame(f,200);m.service();assert m.state().ae_updates==0
m.frame(5,200);m.service();assert m.state().ae_updates==1 and m.state().queued_exposure
m.regs[0xe0]=6;m.service();assert m.state().ae_updates==1 and m.state().waiting_exposure
results.append('AE: frame-start Group Hold, preserved fields, verified writes, conservative N+2 guard')

# Register readback may retain old values until Group Hold applies. Exercise
# all documented 3802[1:0] delays and keep confirmed state old until verification.
for delay in range(4):
    m=ControlMachine(readback_delay=delay+2);m.sensor[0x3802]=0xa0|delay
    assert m.init()==0 and m.state().confirm_frames==delay+3
    m.uc.mem_write(SYMBOLS['app_awb_mode'],(2).to_bytes(4,'little'))
    m.frame(1,200);m.service();m.regs[0xe0]=2;m.service()
    requested=m.state().pending_exposure
    assert requested and m.state().exposure==7103 and m.sensor[0x3e01]==0xbb
    for frame in range(2,delay+5):
        m.frame(frame);m.service()
        assert m.state().enabled and m.state().ae_updates==0 and m.state().exposure==7103
    m.frame(delay+5);m.service()
    assert m.state().ae_updates==1 and m.state().exposure==requested and m.state().last_error==0
    assert m.sensor[0x3802]==0xa0|delay
m=ControlMachine();assert m.init()==0;m.frame(1,200);m.service();m.regs[0xe0]=2;m.service()
m.service(2100);assert not m.state().enabled and m.state().last_error==4
m=ControlMachine();assert m.init()==0;m.frame(1,200);m.service();m.regs[0xe0]=2;m.service()
for frame in (3,4):m.frame(frame);m.service()
m.failure='timeout';m.frame(5);m.service()
assert not m.state().enabled and m.state().last_error==2 and m.state().ae_updates==0
results.append('AE: delayed Group Hold readback for 3802 delays 0..3; confirmation/timeout/read failure preserve last verified exposure')

# A simple independent response plant: mean proportional to exposure, clipped
# to 255. Iterate source frames and verify convergence without overshooting
# legal VTS bounds. AWB is locked to isolate exposure.
m=ControlMachine();assert m.init()==0
m.uc.mem_write(SYMBOLS['app_awb_mode'],(2).to_bytes(4,'little'))
for f in range(1,181):
    exp=((m.sensor[0x3e00]&15)<<12)|(m.sensor[0x3e01]<<4)|(m.sensor[0x3e02]>>4)
    m.frame(f,min(255,max(1,exp*96//1600)))
    m.service(83)
    assert 4<=m.state().exposure<=m.state().maximum
assert 92<=m.state().mean<=100 and abs(m.state().exposure-1600)<100
assert m.state().ae_updates>=2
results.append('AE: independent bright-to-target plant converges within deadband, exposure always in bounds')

def sensor_exposure(m):
    return ((m.sensor[0x3e00]&15)<<12)|(m.sensor[0x3e01]<<4)|(m.sensor[0x3e02]>>4)

def seed_exposure(m,value):
    m.sensor.update({0x3e00:0xa0|(value>>12),0x3e01:(value>>4)&255,0x3e02:((value&15)<<4)|7})

def locked_ae(exposure=1600):
    m=ControlMachine(readback_delay=2)
    seed_exposure(m,exposure)
    assert m.init()==0
    m.uc.mem_write(SYMBOLS['app_awb_mode'],(2).to_bytes(4,'little'))
    return m

# Physical frame response uses delayed sensor exposure, not the software's
# confirmed value. Both directions must reach target promptly at 30 FPS.
response=[]
for initial in (200,7103):
    m=locked_ae(initial);first_settled=None
    for f in range(1,91):
        m.frame(f,min(255,max(1,sensor_exposure(m)*96//1600)))
        m.service(33)
        if m.state().ae_updates and not m.state().waiting_exposure and abs(m.state().mean-96)<=4 and first_settled is None:
            first_settled=f
        assert m.state().enabled and 4<=m.state().exposure<=m.state().maximum
    assert first_settled is not None and first_settled<=45, (initial,first_settled)
    assert abs(m.state().mean-96)<=8
    response.append({'initial':initial,'settled_frame':first_settled,'updates':m.state().ae_updates})
results.append('AE: delayed 30 FPS dark/bright steps settle within 45 frames (1.5 seconds)')

# Noise crosses the old +/-4 deadband, and occasional spikes cross +/-8.
# A fixed scene must not keep rewriting exposure after entering hold.
m=locked_ae()
noise=(0,7,-7,5,-5,10,0,-10,0,6,-6)
for f in range(1,122):
    m.frame(f,96+noise[(f-1)%len(noise)]);m.service(33)
assert m.state().ae_updates==0 and not m.camera_writes and m.state().ae_held
# A sustained small illumination change must still escape hold.
for f in range(122,182):
    m.frame(f,max(1,sensor_exposure(m)*106//1600));m.service(33)
assert m.state().ae_updates>0 and 88<=m.state().mean<=104
results.append('AE: fixed-scene +/-7 noise and isolated +/-10 spikes cause zero writes; sustained drift escapes hold')

# A small bright source switches between 0.8% and 1.4% clipped pixels as
# its edge flickers. It must not pump a dark background around the old 1%
# threshold; model the background brightness independently of that source.
m=locked_ae(800)
for f in range(1,181):
    mean=min(255,max(1,sensor_exposure(m)*96//1600))
    m.frame(f,mean,hot=8 if f%2 else 14);m.service(33)
    assert m.state().enabled
settled_exposure=m.state().exposure;settled_updates=m.state().ae_updates
for f in range(181,301):
    m.frame(f,min(255,max(1,sensor_exposure(m)*96//1600)),hot=8 if f%2 else 14)
    m.service(33)
assert m.state().ae_updates==settled_updates and m.state().exposure==settled_exposure
assert abs(m.state().mean-96)<=8
# Permanently clipped 5% of the image must not force exposure ever downward.
m=locked_ae(800)
for f in range(1,181):
    m.frame(f,min(255,max(1,sensor_exposure(m)*96//1600)),hot=50);m.service(33)
assert 78<=m.state().mean<=94 and m.state().exposure>800
updates=m.state().ae_updates
for f in range(181,241):
    m.frame(f,min(255,max(1,sensor_exposure(m)*96//1600)),hot=50);m.service(33)
assert m.state().ae_updates==updates
results.append('AE: isolated clipped light at 0.8..1.4% and persistent 5% highlights converge without pumping or dark-scene collapse')

# Gain changes also affect AE metering. Allow actual AWB commits while a
# clipped light straddles the old threshold, and verify both loops settle.
m=locked_ae(800)
m.uc.mem_write(SYMBOLS['app_awb_mode'],(1).to_bytes(4,'little'))
for f in range(1,481):
    if m.regs[0x54]:m.ack_gain()
    corrected=(40*m.regs[0x60]+200*256+50*m.regs[0x68])//1024
    mean=min(255,max(1,sensor_exposure(m)*corrected*96//160000))
    m.frame(f,mean,hot=8 if f%2 else 14);m.service(33)
    if f==360:quiet_updates=m.state().ae_updates
    assert m.state().enabled
assert m.state().ae_updates==quiet_updates and m.state().awb_updates>10
assert abs(m.state().mean-96)<=8
assert abs(m.regs[0x60]-640)<=4 and abs(m.regs[0x68]-512)<=4
results.append('AE/AWB: coupled gain-dependent brightness and clipped light converge, with no late AE writes')

# Limits remain quiet when the target brightness is physically unreachable.
for exposure,denominator in ((4,1),(7189,16000)):
    m=locked_ae(exposure)
    for f in range(1,61):
        m.frame(f,min(255,max(1,sensor_exposure(m)*96//denominator)));m.service(33)
    assert not m.camera_writes and m.state().ae_updates==0
results.append('AE: unreachable target at minimum/maximum exposure holds without repeated writes')

# AWB G has TWO samples per cell; many gradual commits approach R=640/B=512.
m=ControlMachine();assert m.init()==0
for f in range(1,121):
    if m.regs[0x54]:m.ack_gain()
    m.frame(f);m.service(83)
    assert 128<=m.regs[0x60]<=1024 and 128<=m.regs[0x68]<=1024
assert abs(m.regs[0x60]-640)<=4 and abs(m.regs[0x68]-512)<=4
assert m.state().ae_updates==0 and m.state().awb_updates>10
results.append('AWB: two-green factor, bounded smooth commits and absolute RAW gain convergence')

# While gain is pending or ACKed with old statistics, AE does not use that
# snapshot. Fixed/lock modes retain or restore the correct confirmed gains.
# AWB_CONFIRM=3: frames 1..3 agree on direction before the first gain commit.
m=ControlMachine();assert m.init()==0
for f in (1,2,3):m.frame(f);m.service()
assert m.state().waiting_gain
m.frame(4,30);m.service();assert not m.camera_writes
m.ack_gain();m.frame(5,30,cfg=0);m.service();assert not m.camera_writes
m.frame(6,30);m.service();assert m.state().queued_exposure
m.regs[0xe0]=7;m.service();assert m.state().ae_updates==0
assert m.state().waiting_exposure
for f in (7,8,9):m.frame(f);m.service();assert not m.regs[0x54]
results.append('coordination: pending gain/old CFG rejected; AWB waits for exposure settling')

for mode in (0,2):
    m=ControlMachine();assert m.init()==0
    m.uc.mem_write(SYMBOLS['app_awb_mode'],mode.to_bytes(4,'little'))
    m.regs.update({0x60:400,0x68:500});m.frame(1);m.service()
    if mode==2:assert not m.regs[0x54]
    else:
        assert m.regs[0x54];m.ack_gain();m.frame(2);m.service()
        assert m.regs[0x60]==0x168 and m.regs[0x68]==0x1a9

# Empty candidates, zero denominators and low candidate fraction preserve WB.
for values in [dict(cells=0),dict(r=0),dict(b=0),dict(cells=1),dict(cells=40)]:
    m=ControlMachine();assert m.init()==0;m.frame(1,**values);m.service();assert not m.regs[0x54]
results.append('AWB: fixed/lock modes, zero-denominator and insufficient-candidate hold')

# Range-only hardware AWB lets coloured objects into the sums. Firmware commits a
# step only after three consecutive snapshots ask for the same R/B direction.
m=ControlMachine();assert m.init()==0
for f in (1,2):m.frame(f);m.service();assert not m.regs[0x54]
m.frame(3);m.service();assert m.regs[0x54]
# Alternating scene colour (red-heavy / blue-heavy) flips direction every frame: no commit.
m=ControlMachine();assert m.init()==0
for f in range(1,41):
    m.frame(f,r=40,b=80) if f%2 else m.frame(f,r=80,b=40)
    m.service(33);assert not m.regs[0x54]
assert m.state().awb_updates==0
# One outlier inside a steady run restarts the count.
m=ControlMachine();assert m.init()==0
m.frame(1);m.service();m.frame(2);m.service();m.frame(3,cells=0);m.service()
m.frame(4);m.service();m.frame(5);m.service();assert not m.regs[0x54]
m.frame(6);m.service();assert m.regs[0x54]
results.append('AWB: three-snapshot direction guard; alternating colour never commits; outlier restarts the count')

for failure in ('nack','timeout','start_dropped','stop_dropped','missing_ack_valid'):
    m=ControlMachine(failure);assert m.init()!=0 and not m.state().enabled and m.state().errors
    assert m.clock<10000000  # Finite bounded waits, including cleanup.
for reg in (0x3e00,0x3e01,0x3e02,0x3812):
    m=ControlMachine();assert m.init()==0;m.frame(1,20);m.service();m.fail_reg=reg
    m.regs[0xe0]=2;m.service()
    assert not m.state().enabled and m.state().status==5 and m.state().exposure==7103
    assert m.camera_writes[-1]==(0x3812,0x30)  # Release attempted even when it NACKs.
m=ControlMachine();assert m.init()==0;m.frame(1,200);m.service();m.failure='ignore_exposure'
m.regs[0xe0]=2;m.service();assert m.state().enabled and m.state().waiting_exposure
for f in (3,4,5):m.frame(f,200);m.service()
assert not m.state().enabled and m.state().exposure==7103 and m.state().last_error==3
assert not m.hold  # ACK without retained register value fails verification.
m=ControlMachine();assert m.init()==0;m.frame(1,96,hot=50);m.service()
assert m.state().queued_exposure<7103  # Highlights reduce exposure inside mean deadband.
results.append('I2C: real BSP NACK/timeout handling; failed exposure never confirmed; hold release always attempted')

class RecoveryFailure(ControlMachine):
    def __init__(self, fault):
        super().__init__();self.recovery_fault=fault
        self.i2c_status=0x600;self.i2c_lines=4
    def i2c_read(self,uc,off,size,data):
        if self.bus_recoveries:
            if off==0x40 and self.recovery_fault=='timeout':return 0x81
            if off==0x40 and self.recovery_fault=='dropped':return 0x800
            if off==0x44 and self.recovery_fault=='sda_low':return 4
        return super().i2c_read(uc,off,size,data)
for fault in ('timeout','dropped','sda_low'):
    m=RecoveryFailure(fault)
    assert m.call('camera_init_cpu')==-4 and not m.camera_writes
    assert m.bus_recoveries==1 and m.clock<10000000
results.append('I2C recovery: stuck bus is bounded; RECOVER timeout/dropped/remaining SDA-low never reports initialized')

m=ControlMachine();m.sensor[0x320e]=0;m.sensor[0x320f]=4;assert m.init()!=0 and not m.state().enabled
m=ControlMachine();m.sensor[0x3107]=0;assert m.init()!=0
m=ControlMachine();assert m.init()==0
for f in (1,2,3):m.frame(f);m.service()
assert m.regs[0x54];m.service(2100)
assert m.state().status==6 and not m.state().enabled  # No ACK is not success.
m=ControlMachine();assert m.init()==0;m.service(1100);assert m.state().status==4
m=ControlMachine('tearing');assert m.init()==0;m.frame(1,20);m.service();assert not m.camera_writes and not m.regs[0x54]
m=ControlMachine();assert m.init()==0;m.frame(1);m.regs[0xd0]|=2;m.service();assert not m.state().enabled
results.append('invalid VTS/ID, missing ACK, no statistics, torn snapshots and capture faults stop new control')

# Frame and publication counters wrap independently; zero publication is valid.
m=ControlMachine();assert m.init()==0
m.frame(0xfffffffe,200,seq=0xfffffffe);m.service();m.regs[0xe0]=0xffffffff;m.service()
assert m.state().ae_updates==0
for frame,seq in [(0xffffffff,0xffffffff),(0,0),(1,1)]:
    m.frame(frame,200,seq=seq);m.service();assert m.state().ae_updates==0
m.frame(2,200,seq=2);m.service();assert m.state().queued_exposure, {n:getattr(m.state(),n) for n,_ in State._fields_}
results.append('32-bit source/statistics wraparound retains valid seq=0 and settling guard')

# Run _start/main with the extension advertised, rather than only invoking
# functions. Legacy startup assertions still enforce readiness and OSD ACK.
class Boot3A(ControlMachine):
    def __init__(self):
        super().__init__();self.boot_frame=0
    def osd_read(self,uc,off,size,data):
        if off<=0x30 or off>=0x200:return Machine.osd_read(self,uc,off,size,data)
        frame=self.clock//8333333
        if frame!=self.boot_frame:
            self.boot_frame=frame
            if self.regs[0x54]:self.ack_gain()
            exp=((self.sensor[0x3e00]&15)<<12)|(self.sensor[0x3e01]<<4)|(self.sensor[0x3e02]>>4)
            self.frame(frame,200 if exp>2000 else 96)
        return ControlMachine.osd_read(self,uc,off,size,data)
    def osd_write(self,uc,off,size,value,data):
        if off<=0x30 or off>=0x200:return Machine.osd_write(self,uc,off,size,value,data)
        return ControlMachine.osd_write(self,uc,off,size,value,data)
m=Boot3A();m.uc.emu_start(SYMBOLS['_start'],0x20000,count=20000000)
assert m.word('app_metrics_updates')==3 and m.video_ready and m.state().enabled
assert m.state().ae_updates>=2 and m.state().awb_updates>0 and 'Software AE/AWB enabled' in m.uart
assert '3A state ' not in m.uart and m.word('app_osd_errors')==0 and m.word('app_ddr_errors')==0
results.append('full _start/main: actual initialization, cooperative 3A service, UART state, OSD ACK and startup gate')

for result in results:print('PASS RV32 3A:',result)
out=ROOT/'reports/simulation/camera_3a_runtime.json'
out.write_text(json.dumps({'checks':results,'response':response,'elf':str(ROOT/'software/firmware/build/soc_video_app.elf')},indent=2))
