"""Embed the deployment coefficients and a complete 32x24 integer self-test."""
from pathlib import Path
import sys,numpy as np
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'ml/style_transfer'))
from integer import IntegerNetwork
APP=ROOT/'software/firmware'
(APP/'style_weights.h').write_bytes((ROOT/'rtl/style/model/style_weights.h').read_bytes())
i=np.arange(32*24,dtype=np.uint32).reshape(24,32)
rgb=np.stack([(i*13+7)&255,(i*7+29)&255,(i*3+97)&255],axis=2).astype(np.uint8)
out=IntegerNetwork(ROOT/'ml/style_transfer/artifacts/integer')(rgb)
def words(x):return x[:,:,0].astype(np.uint32)|(x[:,:,1].astype(np.uint32)<<8)|(x[:,:,2].astype(np.uint32)<<16)
text='/* Integer oracle fixture, little-endian XBGR8888, 32x24. */\n#include <stdint.h>\n'
for label,x in [('input',rgb),('expected',out)]:
    values=words(x).ravel();text+=f'static const uint32_t style_test_{label}[768] = {{\n'
    text+=''.join('  '+','.join(f'0x{int(v):08x}u' for v in values[j:j+8])+',\n' for j in range(0,len(values),8))+'};\n'
(APP/'style_selftest.h').write_text(text)
print('PASS firmware: coefficient image and integer self-test generated')
