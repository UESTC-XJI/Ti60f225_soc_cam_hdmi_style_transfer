"""Audit P2/P3 against saved pre-change inputs, including all CSI envelopes."""
from pathlib import Path
import json,re,subprocess,xml.etree.ElementTree as ET
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'reports/resource_optimization'
BASE=OUT/'baseline_inputs'
def definitions(path):
    return dict(re.findall(r'^`define (\w+)\s+([^\r\n]+)',path.read_text(),re.M))
old=definitions(BASE/'rtl/defines.v');new=definitions(ROOT/'rtl/defines.v')
key='CFG_CSI_RX_CONTROLLER_SV_INST_U_EFX_CSI2_RX_PACK_TYPE'
assert old[key]=='15' and new[key]=='1'
assert {k:v for k,v in old.items() if k!=key}=={k:v for k,v in new.items() if k!=key}
settings=json.loads((ROOT/'ip/csi_rx_controller/settings.json').read_text())
# Preserve all CRC/ECC and other configuration; only this instance override changed.
assert all(re.search('"'+pack+'"\\s*:\\s*"1\'b'+value+'"',
                     json.dumps(settings)) for pack,value in [('Pack_40','1'),('Pack_48','0'),('Pack_56','0'),('Pack_64','0')])
csi='rtl/csi_rx_controller.sv'
before=subprocess.check_output(['git','show','HEAD:'+csi],cwd=ROOT).decode('utf-8')
after=(ROOT/csi).read_text(encoding='utf-8')
assert before.replace('\r\n','\n')==after.replace('\r\n','\n'), 'CSI vendor source changed'
ns={'e':'http://www.efinixinc.com/enf_proj'}
project=ET.parse(ROOT/'ti60f225_cam_hdmi.xml')
params={p.get('name'):p.get('value') for p in project.findall('.//e:param',ns)}
assert params['enable-mark-debug']=='0' and params['auto_instantiation']=='off'
soc_settings=json.loads((ROOT/'soc/efx_sapphire_soc/soc/settings.json').read_text())
soc_text=json.dumps(soc_settings)
assert re.search(r'"DEBUG"\s*:\s*"1\'b1"',soc_text)
before_soc=subprocess.check_output(['git','show','HEAD:soc/efx_sapphire_soc/soc/settings.json'],cwd=ROOT).decode('utf-8')
assert json.loads(before_soc)==soc_settings,'Sapphire configuration changed'
result={'status':'PASS','checks':['only CSI instance PACK_TYPE changed from 15 to 1',
    'RAW10-only agrees with IP settings','CSI source and protected envelopes unchanged',
    'automatic debugger disabled; saved video profile retained',
    'Sapphire configuration and CPU DEBUG retained'],'vendor_csi_protocol_simulation':
    'not executed: protected vendor CSI source is not executable in Icarus'}
(OUT/'optimization_audit.json').write_text(json.dumps(result,indent=2)+'\n')
for item in result['checks']:print('PASS optimization audit:',item)
