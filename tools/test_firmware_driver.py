"""Host protocol model for the generated Sapphire camera/OSD driver."""
import re
from pathlib import Path

table=Path('software/firmware/camera_init_table.h').read_text()
rows=[(int(a,16),int(b,16),int(d)) for a,b,_,d in re.findall(r'\{0x([0-9a-f]+),0x([0-9a-f]+),([01]),(\d+)\}',table)]
assert len(rows)==165 and rows[0][:2]==(0x100,0) and rows[-1][:2]==(0x4501,0xa4)
assert rows[0][2]==5000 and rows[1][2]==0

class OSD:
    def __init__(self):
        self.active=0; self.ack=0; self.pages=[[' ']*80,[' ']*80]; self.status=0
    def commit(self,page):
        self.active=page; self.ack^=1; self.status=self.ack|(self.active<<1)
    def write_string(self,s):
        page=self.active^1
        for i,ch in enumerate(s[:80]): self.pages[page][i]=ch
        self.commit(page)

osd=OSD(); osd.write_string('HELLO SOC'); assert ''.join(osd.pages[osd.active][:9])=='HELLO SOC'
for n in range(20):
    old=osd.ack; osd.write_string(f'RAW {n:02d} RESIZE {n+1:02d} DISP 60 DROP 0 ERR 0'); assert osd.ack!=old
assert ''.join(osd.pages[osd.active][:7])=='RAW 19 '

# Camera-side protocol model: the CPU reads the two-byte sensor ID before
# applying the generated table, then exercises stream stop/start/recovery.
class Sensor:
    def __init__(self): self.reg={0x3107:0xcd,0x3108:0x6b}; self.streaming=False; self.writes=0
    def write(self,reg,val):
        self.reg[reg]=val; self.writes+=1
        if reg==0x0100: self.streaming=(val==1)
    def read(self,reg): return self.reg.get(reg,0)
sensor=Sensor(); assert (sensor.read(0x3107),sensor.read(0x3108))==(0xcd,0x6b)
for reg,val,delay in rows: sensor.write(reg,val)
assert sensor.writes==165 and sensor.reg[0x0100]==1 and sensor.streaming
sensor.write(0x0100,0); assert not sensor.streaming
for reg,val,delay in rows: sensor.write(reg,val)
sensor.write(0x0100,1); assert sensor.streaming
print('PASS firmware driver protocol: 165 camera writes, ID readback, stop/start/recovery, inactive-page commit/ACK, 20 updates')
