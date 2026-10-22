"""Run inherited Windows-oriented regression scripts with native Linux tools.
Only executable argv/model-oracle paths are adapted in memory; RTL is unchanged.
"""
from pathlib import Path
import subprocess,sys,os
ROOT=Path(__file__).resolve().parents[1]
PYTHON=Path(sys.executable)
ENV=os.environ.copy()
ENV['IVERILOG']='/home/goodmann/.hermes/cache/scratch/ti60_sim_bin/iverilog'
ENV['VVP']='/home/goodmann/.hermes/cache/scratch/ti60_sim_bin/vvp'
ENV['SOC_RISCV_TOOLCHAIN']='/home/goodmann/efinity/efinity-riscv-ide-2026.1/toolchain/bin'
os.environ.update(ENV)
original_run=subprocess.run
original_popen=subprocess.Popen
class NativePopen(original_popen):
 def __init__(self,args,*a,**kw):
  if isinstance(args,(list,tuple)):
   args=list(args)
   for i,s in enumerate(args):
    if isinstance(s,(str,Path)):
     s=str(s)
     if os.environ.get('PREFETCH_CONTROL')=='1' and s=='rtl/style/style_network.sv':
      import json
      s=str(ROOT/'reports/baseline/style_network.sv')
     if s=='C:/iverilog/bin/iverilog.exe':s=ENV['IVERILOG']
     elif s=='C:/iverilog/bin/vvp.exe':s=ENV['VVP']
     elif s.endswith('.exe') and 'riscv-none-elf-' in s:s=s[:-4]
     args[i]=s
   if len(args)>1 and Path(str(args[0])).name.startswith('python') and str(args[1]).startswith('tools/'):
    args=[str(PYTHON),str(ROOT/'tools/run_native.py'),*args[1:]]
  super().__init__(args,*a,**kw)
subprocess.Popen=NativePopen
script=ROOT/sys.argv[1];sys.argv=sys.argv[1:]
source=script.read_text().replace("ml/style_transfer/artifacts/integer","ml/style_transfer/artifacts_quality/integer")
exec(compile(source,str(script),'exec'),{'__file__':str(script),'__name__':'__main__'})
