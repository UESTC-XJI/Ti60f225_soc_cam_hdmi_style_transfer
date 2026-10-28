import re
from pathlib import Path

text=Path('rtl/cam_i2c_ctrl/i2c/i2c_master_reg_rom.v').read_text(encoding='utf-8')
rows=[]
for idx,reg,val,rd in re.findall(r'^ROM\[8\'h([0-9a-f]+)\] = \{16\'h([0-9a-f]+),8\'h([0-9a-f]+),1\'b([01])\};',text,re.I|re.M):
    rows.append((int(idx,16),int(reg,16),int(val,16),int(rd)))
rows.sort()
out=['// Generated from the active RTL camera table; order and delays are preserved.', '#pragma once', '#include <stdint.h>', 'typedef struct { uint16_t reg; uint8_t value; uint8_t readback; uint16_t delay_us; } camera_init_entry_t;', f'enum {{ CAMERA_INIT_COUNT = {len(rows)} }};', 'static const camera_init_entry_t camera_init_table[CAMERA_INIT_COUNT] = {']
for _,reg,val,rd in rows:
    delay = 5000 if reg == 0x0100 and val == 0 else (1000 if reg == 0x0100 and val == 1 else 0)
    out.append(f'  {{0x{reg:04x},0x{val:02x},{rd},{delay}}},')
out += ['};', '']
Path('software/firmware').mkdir(parents=True,exist_ok=True)
Path('software/firmware/camera_init_table.h').write_text('\n'.join(out),encoding='utf-8')
print('generated',len(rows),'entries')
