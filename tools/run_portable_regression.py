"""Portable execution of existing directed RTL regressions; sources unmodified."""
from pathlib import Path
import os,subprocess,sys
R=Path(__file__).resolve().parents[1];O=R/'reports/validation';O.mkdir(parents=True,exist_ok=True)
iv=os.environ['IVERILOG'];vv=os.environ['VVP']
class Result: pass
original=subprocess.run
def run(cmd,*args,**kw):
    if isinstance(cmd,list):
        cmd=list(cmd)
        if cmd[0]=='C:/iverilog/bin/iverilog.exe':cmd[0]=iv
        if cmd[0]=='C:/iverilog/bin/vvp.exe':cmd[0]=vv
    return original(cmd,*args,**kw)
subprocess.run=run
name=sys.argv[1]
sys.argv=[str(R/'tools'/name),*sys.argv[2:]]
namespace={'__file__':str(R/'tools'/name),'__name__':'__main__'}
exec(compile((R/'tools'/name).read_text(),str(R/'tools'/name),'exec'),namespace)
