from pathlib import Path
import re,json,hashlib
r=Path(__file__).resolve().parents[1]
b=r.parent/'Ti60f225_soc_cam_hdmi_style_demo'
s=(r/'soc/efx_sapphire_soc/soc/soc.v').read_text()
assert 'system_ddr_ddrLogic_cc_fifo' not in s, 'DDR CDC FIFO remains'
assert not re.search(r'input\s+(?:wire\s+)?io_memoryClk\b',s)
assert 'jtagCtrl' in s and 'userInterruptA' in s

def ports(text):
 text=text[text.index('module EfxSapphireSoc ('):];text=text[:text.index('\n);')]
 return {n:(d,w.strip()) for d,w,n in re.findall(r'\b(input|output)\s+(?:wire\s+|reg\s+)?(\[[^\]]+\]\s*)?(\w+)',text)}
a=ports((b/'soc/efx_sapphire_soc/soc/source/hardware/netlist/EfxSapphireSoc.v').read_text())
c=ports((r/'work_lite_generator/hardware/netlist/EfxSapphireSoc.v').read_text())
assert a.keys()-c.keys()=={'io_memoryClk','io_memoryReset'}
assert not c.keys()-a.keys()
assert all(a[n]==c[n] for n in c)
def defines(p):return dict(re.findall(r'^#define\s+(\w+)\s+(.+)$',p.read_text(),re.M))
assert defines(r/'software/bsp/EfxSapphireSoc/include/soc.h')==defines(r/'work_lite_generator/bsp/efinix/EfxSapphireSoc/include/soc.h')
config=(r/'reports/versions/lite-unified-clock-experiment/soc_config_lite').read_text()
assert '--noDdrAClock' in config and '--lowArea 5' in config
assert not any(x in config for x in ['--noMulDiv','--noBarrelShifter','--reducedCsr'])
m=json.loads((r/'reports/versions/lite-unified-clock-experiment/baseline_manifest.json').read_text())
for n,h in m['files'].items():assert hashlib.sha256((b/n).read_bytes()).hexdigest()==h,n
print('PASS: CDC absent; 163 remaining core ports identical; BSP macros identical; M/barrel/full CSR retained; baseline unchanged')
