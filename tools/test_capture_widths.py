"""Baseline differential simulation plus strict internal range budgets."""
from pathlib import Path
import os,subprocess,sys
R=Path(__file__).resolve().parents[1];B=R/'work/validation';B.mkdir(parents=True,exist_ok=True)
O=R/'reports/validation';O.mkdir(parents=True,exist_ok=True)
s=(R/'reports/baseline/rtl/isp/capture_frame_stats.sv').read_text().replace('module capture_frame_stats #(', 'module capture_frame_stats_baseline #(')
(B/'capture_frame_stats_baseline.sv').write_text(s)
full='--full' in sys.argv
args=[] if full else ['-Pcapture_equivalence_tb.W=64','-Pcapture_equivalence_tb.H=16']
cmd=[os.environ['IVERILOG'],'-g2012','-s','capture_equivalence_tb','-o',str(B/'capture_eq.vvp'),*args,'tests/capture_equivalence_tb.sv','rtl/isp/capture_frame_stats.sv',str(B/'capture_frame_stats_baseline.sv')]
p=subprocess.run(cmd,cwd=R,capture_output=True,text=True);assert p.returncode==0,p.stderr
p=subprocess.run([os.environ['VVP'],str(B/'capture_eq.vvp')],cwd=R,capture_output=True,text=True,timeout=600)
(O/('capture_full.log' if full else 'capture_small.log')).write_text(p.stdout+p.stderr)
print(p.stdout);assert p.returncode==0,p.stderr
# Structural budget test proves the optimization is present, separate from equivalence.
tb='''module width_budget_tb;
capture_frame_stats dut();
initial begin
if($bits(dut.rs)>22 || $bits(dut.gs)>23 || $bits(dut.ys)>23 || $bits(dut.samples)>15 || $bits(dut.cells)>14)$fatal(1,"internal width budget not implemented");
$display("PASS range budget: R/B22 G/Y23 AE15 AWB14");$finish;
end
endmodule
'''
(B/'width_budget_tb.sv').write_text(tb)
p=subprocess.run([os.environ['IVERILOG'],'-g2012','-s','width_budget_tb','-o',str(B/'width.vvp'),str(B/'width_budget_tb.sv'),'rtl/isp/capture_frame_stats.sv'],cwd=R,capture_output=True,text=True);assert p.returncode==0,p.stderr
p=subprocess.run([os.environ['VVP'],str(B/'width.vvp')],cwd=R,capture_output=True,text=True)
(O/'width_budget.log').write_text(p.stdout+p.stderr);print(p.stdout);assert p.returncode==0
