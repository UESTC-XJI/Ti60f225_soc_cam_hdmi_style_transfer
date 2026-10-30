"""Exercise the actual B RV32 firmware with modeled UART0, keys, DDR and timer.
Install unicorn/pyelftools into work/peripheral_test_deps; no board required.
"""
from pathlib import Path
import sys, struct, json, zlib
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'work/peripheral_test_deps'))
from unicorn import Uc,UC_ARCH_RISCV,UC_MODE_RISCV32,UC_HOOK_CODE
from unicorn.riscv_const import UC_RISCV_REG_PC,UC_RISCV_REG_SP,UC_RISCV_REG_GP,UC_RISCV_REG_RA,UC_RISCV_REG_A0,UC_RISCV_REG_A1
from elftools.elf.elffile import ELFFile

class Board:
 def __init__(self):
  self.uc=Uc(UC_ARCH_RISCV,UC_MODE_RISCV32)
  self.uc.mem_map(0,0x20000);self.uc.mem_map(0x01000000,0x100000)
  self.uc.mem_map(0x05800000,0x140000);self.uc.mem_map(0x06f00000,0x10000)
  with (ROOT/'software/firmware/build/soc_video_app.elf').open('rb') as f:
   elf=ELFFile(f);self.sym={s.name:s.entry.st_value for s in elf.get_section_by_name('.symtab').iter_symbols()}
   assert not [s.name for s in elf.get_section_by_name('.symtab').iter_symbols() if s.name and s.entry.st_shndx=='SHN_UNDEF']
   for s in elf.iter_segments():
    if s.header.p_type=='PT_LOAD':self.uc.mem_write(s.header.p_vaddr,s.data())
  self.uc.reg_write(UC_RISCV_REG_SP,self.sym['_sp']);self.uc.reg_write(UC_RISCV_REG_GP,self.sym['__global_pointer$'])
  self.rx=bytearray();self.tx=bytearray();self.keys=0;self.knob=3;self.ui=3;self.now=0;self.uart={};self.style={4:16}
  self.uc.mmio_map(0xf8010000,0x1000,self.ur,None,self.uw,None)
  self.uc.mmio_map(0xf8100000,0x1000,self.vr,None,self.vw,None)
  self.uc.mmio_map(0xf8b00000,0x10000,self.tr,None,lambda *a:None,None)
  for addr in range(0x1000,self.sym['_edata'],4):
   if bytes(self.uc.mem_read(addr,4))==b'\x0f\x50\x00\x00':self.uc.hook_add(UC_HOOK_CODE,self.code,begin=addr,end=addr)
 def code(self,uc,addr,size,data):
  if bytes(uc.mem_read(addr,4))==b'\x0f\x50\x00\x00':uc.reg_write(UC_RISCV_REG_PC,addr+4)
 def ur(self,uc,off,size,data):
  if off==4:return (128<<16)|(len(self.rx)<<24)
  if off==0:return self.rx.pop(0) if self.rx else 0
  return self.uart.get(off,0)
 def uw(self,uc,off,size,val,data):
  if off==0:self.tx.append(val&255)
  else:self.uart[off]=val
 def vr(self,uc,off,size,data):
  if off==0x134:return self.keys
  if off==0x130:return self.ui
  if off==0x54:return self.knob<<2
  if off==0x208:return 16
  if off==0x288:return 0x80000008
  return self.style.get(off-0x200,0)
 def vw(self,uc,off,size,val,data):
  if off==0x130:self.ui=val
  elif off>=0x200:self.style[off-0x200]=val
 def tr(self,uc,off,size,data):return self.now&0xffffffff if off==0xbff8 else self.now>>32 if off==0xbffc else 0
 def call(self,name,*args):
  for reg,val in zip([UC_RISCV_REG_A0,UC_RISCV_REG_A1],args):self.uc.reg_write(reg,val)
  self.uc.reg_write(UC_RISCV_REG_RA,0x100)
  self.uc.emu_start(self.sym[name],0x100,count=3000000)
  assert self.uc.reg_read(UC_RISCV_REG_PC)==0x100,(name,hex(self.uc.reg_read(UC_RISCV_REG_PC)))
  return self.uc.reg_read(UC_RISCV_REG_A0)
 def word(self,name):return int.from_bytes(self.uc.mem_read(self.sym[name],4),'little')
 def poll(self,ms=1):
  self.now+=ms*100000;self.call('qse_ble_poll',self.now,0)
 def drain(self):
  for _ in range(100):
   if not self.call('qse_ble_tx_pending'):return
   self.poll(20)
  raise AssertionError('TX stuck')
 def command(self,s):
  self.drain();self.tx.clear();self.rx.extend((s+'\n').encode());self.poll();self.drain();return self.tx.decode('ascii')

def main():
 b=Board();b.call('qse_ble_init',0,0);assert b.ui==3 and b.uart[8]==96 and b.word('qse_ble_rate')==1500
 # A 19 ms press is rejected; 20 ms accepted; a held key never repeats.
 b.keys=1;b.poll();b.poll(19);assert b.ui==3;b.keys=0;b.poll();b.poll(25);assert b.ui==3
 b.keys=1;b.poll();b.poll(20);assert b.ui==2
 b.poll(100);assert b.ui==2
 b.keys=0;b.poll();b.poll(20);b.keys=1;b.poll();b.poll(20);assert b.ui==3
 b.keys=0;b.poll();b.poll(20);b.keys=2;b.poll();b.poll(20);assert b.ui==1
 b.keys=0;b.poll();b.poll(20)
 b.keys=3;b.poll();b.poll(20);assert b.ui==2
 b.keys=0;b.poll();b.poll(20)
 assert 'OSD,1' in b.command('OSD,1')
 assert 'VIEW,1' in b.command('VIEW,1') and b.ui==3
 assert 'OSD,0' in b.command('OSD,0') and b.ui==2
 assert 'OSD,1' in b.command('OSD') and b.ui==3
 for n,bank in [(0,4),(1,0),(2,3),(3,3)]:
  s=b.command(f'KNOB,{n}');assert f'KNOB,{n}' in s and f'BANK,{bank},' in s,s
 for n in range(5):assert f'SLOT,{n}' in b.command(f'SLOT,{n}') and b.call('style_active_bank')==n
 s=b.command('STATE');assert all(x in s for x in ['KNOB,3','SLOT,4','BANK,4,rainbow','OSD,1','VIEW,1','RATE,1500']),s
 assert b.command('SLOT,5')=='SLOT,5\n' and b.call('style_active_bank')==4
 assert b.command('hello')=='hello\n'
 assert 'RATE,200' in b.command('RATE,0');assert 'RATE,12800' in b.command('RATE,999999');b.command('RATE,1500')
 for invalid in ['VIEW,2','OSD,2','KNOB,4','SLOT,-1','SLOT,','V','OS','KN']:
  before=b.ui;assert b.command(invalid)==invalid+'\n' and b.ui==before
 for w in [160,640]:assert 'IMG,ERR,ARG' in b.command(f'SNAP,{w}')
 # Physical knob keeps B's raw mapping and takes over after a remote selection.
 for raw,bank in [(1,0),(0,4),(2,3),(3,3)]:
  b.knob=raw;b.call('style_knob_apply',raw)
  assert b.call('style_active_bank')==bank
 print('PASS RV32 keys: active-high 20 ms bounce/hold/release; VIEW/OSD; B knob takeover; SLOT0..4; STATE/BANK; UART0 pacing')
 # Snapshot uses actual RGB-biased DDR and actual incremental JPEG encoder.
 b.drain();b.tx.clear();b.uc.mem_write(0x05800000,b''.join(((x//8+y//8)%2*0xffffff^0x808080).to_bytes(4,'little') for y in range(240) for x in range(320)))
 assert 'IMG,ERR' not in b.command('SNAP,320,60,4')
 for _ in range(3000):
  b.poll()
  if b.word('qse_imgtx_state')==6:break
 else:raise AssertionError('snapshot did not encode')
 size=b.word('qse_imgtx_jpeg_bytes');jpg=bytes(b.uc.mem_read(0x01080000,size))
 assert jpg[:2]==b'\xff\xd8' and jpg[-2:]==b'\xff\xd9'
 from PIL import Image
 import io
 im=Image.open(io.BytesIO(jpg));im.load();assert im.size==(320,240)
 assert max(im.getpixel((4,4)))<12 and min(im.getpixel((12,4)))>240
 # Capture the real wire transfer, ACKing each window after UART drains.
 wire=bytearray(b.tx);b.tx.clear()
 for _ in range(3000):
  b.poll(20);wire.extend(b.tx);b.tx.clear()
  # ACK only complete packets received so far.
  off=0;ack=0
  while off+7<=len(wire):
   if wire[off:off+2]!=b'\xa5\x5a':off+=1;continue
   n=wire[off+4]
   if off+n+7>len(wire):break
   ack=max(ack,int.from_bytes(wire[off+2:off+4],'little')+1);off+=n+7
  if ack:b.rx.extend(f'ACK,{ack}\n'.encode())
  if b.word('qse_imgtx_state')==0:
   b.drain();wire.extend(b.tx);break
 else:raise AssertionError('snapshot transfer did not finish')
 assert b'IMG,END' in wire
 out=ROOT/'reports/simulation/peripheral_merge';out.mkdir(parents=True,exist_ok=True)
 (out/'snapshot.jpg').write_bytes(jpg);(out/'snapshot_stream.bin').write_bytes(wire)
 (out/'validation.json').write_text(json.dumps({'keys':'PASS','commands':'PASS','knob':'PASS','snapshot':'PASS','size':[320,240],'jpeg_bytes':size,'crc32':f'{zlib.crc32(jpg):08x}'}))
 print('PASS RV32 native 320x240 JPEG, bias correction, ACK-window UART transfer:',size,'bytes')
if __name__=='__main__':main()
