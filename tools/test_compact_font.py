"""Compare all byte characters/rows with immutable baseline, then enforce compact storage."""
from pathlib import Path
import os,re,subprocess
R=Path(__file__).resolve().parents[1]
O=R/'reports/validation';O.mkdir(parents=True,exist_ok=True)
B=R/'work/validation';B.mkdir(parents=True,exist_ok=True)
old=(R/'reports/baseline/rtl/soc_integration/osd_font8x16.sv').read_text()
font=[0]*4096
for a,v in re.findall(r"rom\[12'h([0-9a-f]+)\] = 8'h([0-9a-f]+)",old):font[int(a,16)]=int(v,16)
(B/'font_oracle.hex').write_text(''.join(f'{v:02x}\n' for v in font))
tb='''`timescale 1ns/1ps
module font_equivalence_tb;
reg clk=0;always #5 clk=~clk;
reg [7:0] ch;reg [3:0] row;wire [7:0] bits;
reg [7:0] oracle[0:4095];integer i;
osd_font8x16 dut(.*);
initial begin
$readmemh("work/validation/font_oracle.hex",oracle);
for(i=0;i<4096;i=i+1)begin
 @(negedge clk);ch=i/16;row=i%16;
 @(posedge clk);#1;if(bits!==oracle[i])$fatal(1,"font mismatch address=%0d",i);
end
@(negedge clk);ch=8'hxx;row=0;@(posedge clk);#1;
if(bits!==0)$fatal(1,"unknown character must be blank");
$display("PASS font: all 256 characters x16 rows x8 pixel bits; unknown character blank");$finish;
end
endmodule
'''
(B/'font_equivalence_tb.sv').write_text(tb)
iv=os.environ['IVERILOG'];vv=os.environ['VVP']
cmd=[iv,'-g2012','-s','font_equivalence_tb','-o',str(B/'font.vvp'),str(B/'font_equivalence_tb.sv'),'rtl/soc_integration/osd_font8x16.sv']
p=subprocess.run(cmd,cwd=R,capture_output=True,text=True);assert p.returncode==0,p.stderr
p=subprocess.run([vv,str(B/'font.vvp')],cwd=R,capture_output=True,text=True)
(O/'font_equivalence.log').write_text(p.stdout+p.stderr)
print(p.stdout);assert p.returncode==0,p.stderr
text=(R/'rtl/soc_integration/osd_font8x16.sv').read_text()
m=re.search(r'rom\s*\[0:(\d+)\]',text)
assert m and int(m[1])<2048,'font ROM still exceeds compact printable-ASCII depth'
print('PASS compact font depth')
