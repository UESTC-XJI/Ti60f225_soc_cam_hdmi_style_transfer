"""Directed RAM regression; protected CSI is checked by synthesis, not Icarus."""
from pathlib import Path
import os,re,subprocess
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'reports/resource_optimization'
BUILD=ROOT/'work/resource_optimization_tests'
OUT.mkdir(parents=True,exist_ok=True);BUILD.mkdir(parents=True,exist_ok=True)
IVERILOG=os.environ.get('IVERILOG','C:/iverilog/bin/iverilog.exe')
VVP=os.environ.get('VVP','C:/iverilog/bin/vvp.exe')
font=[0]*4096
for addr,value in re.findall(r"rom\[12'h([0-9a-f]+)\] = 8'h([0-9a-f]+)",
                            (ROOT/'rtl/soc_integration/osd_font8x16.sv').read_text()):
    font[int(addr,16)]=int(value,16)
oracle=BUILD/'font_oracle.hex'
oracle.write_text(''.join(f'{value:02x}\n' for value in font))
jobs=[('osd_bram_pixels_tb',['rtl/soc_integration/osd_text_double_buffer.sv',
                           'rtl/soc_integration/osd_font8x16.sv'],'osd_pixels')]
for top,sources,name in jobs:
    sim=BUILD/(top+'.vvp')
    compile_result=subprocess.run([IVERILOG,'-g2012','-grelative-include','-I','rtl',
        '-s',top,'-o',str(sim),'tests/'+top+'.sv',*sources],cwd=ROOT,capture_output=True,text=True)
    assert compile_result.returncode==0,compile_result.stderr
    result=subprocess.run([VVP,str(sim),'+font='+oracle.as_posix()],cwd=ROOT,
                          capture_output=True,text=True,timeout=60)
    (OUT/(name+'.log')).write_text(compile_result.stderr+result.stdout+result.stderr)
    print(result.stdout,end='')
    assert result.returncode==0,result.stderr
