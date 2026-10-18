"""Embed the deployment coefficients and a complete 32x24 integer self-test."""
from pathlib import Path
import sys,os,numpy as np
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'ml/style_transfer'))
from integer import IntegerNetwork
APP=ROOT/'software/firmware'
(APP/'style_weights.h').write_bytes((ROOT/'rtl/style/model/style_weights.h').read_bytes())
# The self-test fixture MUST come from the same model as the coefficients above,
# otherwise the on-board CPU self-test compares against the wrong expectation.
# Set STYLE_ORACLE_DIR to point at another export (e.g. a different style).
ORACLE=Path(os.environ.get('STYLE_ORACLE_DIR', ROOT/'reports/ukiyoe/export'))
if not (ORACLE/'parameters.npz').exists():
    ORACLE=ROOT/'ml/style_transfer/artifacts/integer'
i=np.arange(32*24,dtype=np.uint32).reshape(24,32)
rgb=np.stack([(i*13+7)&255,(i*7+29)&255,(i*3+97)&255],axis=2).astype(np.uint8)
out=IntegerNetwork(ORACLE)(rgb)
def words(x):return x[:,:,0].astype(np.uint32)|(x[:,:,1].astype(np.uint32)<<8)|(x[:,:,2].astype(np.uint32)<<16)
text='/* Integer oracle fixture, little-endian XBGR8888, 32x24. */\n#include <stdint.h>\n'
for label,x in [('input',rgb),('expected',out)]:
    values=words(x).ravel();text+=f'static const uint32_t style_test_{label}[768] = {{\n'
    text+=''.join('  '+','.join(f'0x{int(v):08x}u' for v in values[j:j+8])+',\n' for j in range(0,len(values),8))+'};\n'
(APP/'style_selftest.h').write_text(text)
print(f'PASS firmware: coefficient image and integer self-test generated (oracle: {ORACLE.relative_to(ROOT)})')

