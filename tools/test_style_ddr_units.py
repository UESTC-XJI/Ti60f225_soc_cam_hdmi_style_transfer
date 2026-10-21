"""Beat buffer, diagnostic counter semantics and bounded urgent arbitration."""
from pathlib import Path
import subprocess
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'reports/style_demo/ddr_optimization/units';OUT.mkdir(parents=True,exist_ok=True)
original=(ROOT/'tests/axi_shared_ddr_2m_tb.sv').read_text()
text=original[:original.index('  initial begin')]
text=text.replace('module axi_shared_ddr_2m_tb;', 'module style_adaptive_arb_tb;')
text=text.replace("wire video_read_urgent=1'b0;", "reg video_read_urgent=1'b1;")
text=text.replace('axi_shared_ddr_2m dut(.*);', "axi_shared_ddr_2m #(.DYNAMIC_VIDEO_READ(1'b1)) dut(.*);")
text+='''
  integer cnn_grants=0,video_grants=0,streak=0,max_streak=0;
  always @(posedge clk)if(rst_n&&allow_access)begin
    if(cpu_arready)begin cnn_grants=cnn_grants+1;streak=0;end
    if(vid_arready)begin
      video_grants=video_grants+1;streak=streak+1;
      if(streak>max_streak)max_streak=streak;
      if(cpu_arvalid&&streak>(video_read_urgent ? 3:1))$fatal(1,"CNN starvation streak=%0d",streak);
    end
    if(cpu_rvalid&&cpu_rready&&cpu_rid!=cpu_arid)$fatal(1,"CNN ID routing");
    if(vid_rvalid&&vid_rready&&vid_rid!=vid_arid)$fatal(1,"display ID routing");
  end
  initial begin
    repeat(4)@(negedge clk);rst_n=1;allow_access=1;cpu_arvalid=1;vid_arvalid=1;
    wait(ar_count>=80);@(negedge clk);video_read_urgent=0;
    // The first fair grant can follow a preceding urgent streak; let the
    // currently outstanding burst complete before assessing fair alternation.
    wait(cpu_arready);@(negedge clk);
    wait(ar_count>=180);@(negedge clk);cpu_arvalid=0;vid_arvalid=0;
    wait(!dut.rd_busy);@(negedge clk);
    if(axi_error_count||cnn_grants<60||video_grants<60||max_streak!=3)$fatal(1,"coverage/errors");
    $display("PASS adaptive arbitration: urgent display <=3 bypass bursts, nonurgent round-robin, 180 reads, full IDs, no starvation");$finish;
  end
  initial begin #1000000;$fatal(1,"arbitration timeout");end
endmodule
'''
# Hold strict urgent mode until a CNN grant before switching to fair mode.
text=text.replace('wait(ar_count>=80);@(negedge clk);video_read_urgent=0;', 'wait(ar_count>=80);wait(cpu_arready);@(negedge clk);video_read_urgent=0;')
(OUT/'adaptive_tb.sv').write_text(text)
jobs=[('style_display_beats_tb','tests/style_display_beats_tb.sv',['rtl/style/style_display_beats.sv']),
      ('style_control_fifo_tb','tests/style_control_fifo_tb.sv',['rtl/style/style_async_fifo.sv']),
      ('style_ddr_profiler_tb','tests/style_ddr_profiler_tb.sv',['rtl/style/style_ddr_profiler.sv']),
      ('style_adaptive_arb_tb',(OUT/'adaptive_tb.sv').relative_to(ROOT).as_posix(),['rtl/soc_integration/axi_shared_ddr_2m.sv'])]
for top,tb,modules in jobs:
    sim=OUT/(top+'.vvp')
    c=subprocess.run(['C:/iverilog/bin/iverilog.exe','-g2012','-s',top,'-o',str(sim),tb,*modules],cwd=ROOT,capture_output=True,text=True)
    assert c.returncode==0,c.stderr
    r=subprocess.run(['C:/iverilog/bin/vvp.exe',str(sim)],cwd=ROOT,capture_output=True,text=True,timeout=60)
    (OUT/(top+'.log')).write_text(c.stderr+r.stdout+r.stderr)
    print(r.stdout,flush=True);assert r.returncode==0,r.stderr
