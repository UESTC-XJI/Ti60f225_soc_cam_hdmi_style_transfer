"""Run the actual ELF from main through animation gating and device init order.
MMIO models the boot peripheral; existing device drivers are intercepted only
at their public boundaries so this verifies the compiled startup sequencing.
"""
from pathlib import Path
import sys
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'work/peripheral_test_deps'))
from test_qse_mainline import Board
from unicorn import UC_HOOK_CODE
from unicorn.riscv_const import UC_RISCV_REG_PC,UC_RISCV_REG_RA,UC_RISCV_REG_A0
class Startup(Board):
 def __init__(self):
  self.started=False;self.status=0;self.start_time=0;self.events=[]
  super().__init__()
  self.uc.mem_map(0xf8016000,0x1000)
  self.uc.hook_add(UC_HOOK_CODE,self.step)
 def tr(self,uc,off,size,data):
  if off==0xbff8:self.now+=1000000
  return super().tr(uc,off,size,data)
 def vr(self,uc,off,size,data):
  if off==0x13c:
   if self.started and self.now-self.start_time>=260000000:self.status=2
   return self.status
  return super().vr(uc,off,size,data)
 def vw(self,uc,off,size,val,data):
  if off==0x138:
   if val==1:self.started=True;self.status=1;self.start_time=self.now;self.events.append('animation')
   if val==2:
    assert 'camera_init_cpu' in self.events and self.status==2
    assert self.ui==5
    self.events.append('live_arm');uc.emu_stop()
  super().vw(uc,off,size,val,data)
 def step(self,uc,addr,size,data):
  names=['bsp_init','app_ddr_test','style_init_and_selftest','style_stream_enable','camera_bus_init','bsp_uDelay','camera_init_cpu','osd_write_string']
  for name in names:
   if name in self.sym and addr==self.sym[name]:
    assert self.status==2,(name,'initialization before fade out')
    self.events.append(name);uc.reg_write(UC_RISCV_REG_A0,0);uc.reg_write(UC_RISCV_REG_PC,uc.reg_read(UC_RISCV_REG_RA));return
b=Startup()
b.uc.emu_start(b.sym['main'],0x100,count=5000000)
assert b.events[0]=='animation' and b.events[-1]=='live_arm',b.events
assert b.events.index('app_ddr_test')<b.events.index('style_init_and_selftest')<b.events.index('camera_init_cpu')
assert b.ui==5 and b.word('app_boot_errors')==0
print('PASS actual RV32 main: fade completes before device initialization; raw single default; arm after camera init')
print(' -> '.join(b.events))
