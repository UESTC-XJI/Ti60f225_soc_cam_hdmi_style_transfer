"""Urgent display must win beyond the CNN bypass limit; fairness resumes."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'reports/style_demo/display_deadline/units'
OUT.mkdir(parents=True, exist_ok=True)
source = (ROOT/'tests/axi_shared_ddr_2m_tb.sv').read_text()
text = source[:source.index('  initial begin')]
text = text.replace('module axi_shared_ddr_2m_tb;', 'module style_deadline_arb_tb;')
text = text.replace("wire video_read_urgent=1'b0;", "reg video_read_urgent=1'b1;")
text = text.replace('axi_shared_ddr_2m dut(.*);', "axi_shared_ddr_2m #(.DYNAMIC_VIDEO_READ(1'b1),.URGENT_OVERRIDES_FAIRNESS(1'b1),.RESERVE_URGENT_READ(1'b1)) dut(.*);")
text += '''
  integer cnn_grants=0,video_grants=0,urgent_grants=0,fair_streak=0;
  always @(posedge clk)if(rst_n&&allow_access)begin
    if(cpu_arready)begin
      if(video_read_urgent&&vid_arvalid)$fatal(1,"CNN grant missed urgent display deadline");
      cnn_grants=cnn_grants+1;fair_streak=0;
    end
    if(vid_arready)begin
      video_grants=video_grants+1;
      if(video_read_urgent)begin urgent_grants=urgent_grants+1;fair_streak=0;end
      else begin
        fair_streak=fair_streak+1;
        if(cpu_arvalid&&fair_streak>1)$fatal(1,"nonurgent CNN starvation");
      end
    end
    if(cpu_rvalid&&cpu_rready&&cpu_rid!=cpu_arid)$fatal(1,"CNN ID routing");
    if(vid_rvalid&&vid_rready&&vid_rid!=vid_arid)$fatal(1,"display ID routing");
  end
  initial begin
    repeat(4)@(negedge clk);rst_n=1;allow_access=1;cpu_arvalid=1;vid_arvalid=1;
    wait(ar_count>=80);@(negedge clk);vid_arvalid=0;
    wait(!dut.rd_busy);repeat(20)@(negedge clk);
    if(cnn_grants!=0)$fatal(1,"CNN inserted in urgent display inter-burst gap");
    video_read_urgent=0;vid_arvalid=1;
    wait(ar_count>=180);@(negedge clk);cpu_arvalid=0;vid_arvalid=0;
    wait(!dut.rd_busy);@(negedge clk);
    if(axi_error_count||urgent_grants<80||cnn_grants<49||video_grants<129)$fatal(1,"coverage/errors");
    $display("PASS display deadline: >=80 urgent bursts, inter-burst reservation, nonurgent round-robin, 180 reads, full IDs");$finish;
  end
  initial begin #1000000;$fatal(1,"deadline arbitration timeout");end
endmodule
'''
tb = OUT/'tb.sv'
tb.write_text(text)
sim = OUT/'test.vvp'
compile = subprocess.run(['C:/iverilog/bin/iverilog.exe','-g2012','-s','style_deadline_arb_tb','-o',str(sim),str(tb),'rtl/soc_integration/axi_shared_ddr_2m.sv'],cwd=ROOT,capture_output=True,text=True)
assert compile.returncode == 0, compile.stderr
result = subprocess.run(['C:/iverilog/bin/vvp.exe',str(sim)],cwd=ROOT,capture_output=True,text=True,timeout=60)
(OUT/'simulation.log').write_text(compile.stderr+result.stdout+result.stderr)
print(result.stdout,flush=True)
assert result.returncode == 0, result.stderr
