"""Compare display pixels under sustained CNN reads and burst return latency."""
from pathlib import Path
import subprocess
import json
import re

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'reports/style_demo/display_deadline/contention'
OUT.mkdir(parents=True,exist_ok=True)
original=(ROOT/'tests/style_display_tb.sv').read_text()
results={}
for hard in (0,1,2):
    text=original.replace('module style_display_tb;', 'module style_contention_tb;')
    text=text.replace('wire arready=!read_active&&rng[0];wire rvalid=read_active&&rhold&&block_cycles==0;', 'wire arready,rvalid; wire mrready; wire marvalid; wire [31:0] maraddr; wire [7:0] marlen; wire [3:0] marid; reg [3:0] saved_id; integer return_delay=0; wire mrvalid=read_active&&rhold&&return_delay==0;')
    text=text.replace('wire rlast=beat==len;wire [1:0] rresp=0;', 'wire rlast;wire [1:0] rresp;')
    text=text.replace('wire [127:0] rdata=data_at(address);', 'wire [127:0] rdata;')
    ports=['.clk(clk)','.rst_n(rst_n)', '.allow_access(rst_n)', '.video_read_urgent(read_urgent)']
    # Writes are inactive: this test isolates competition for the read channel.
    for name in ('cpu','vid'):
        for sig,val in {'awid':"8'b0",'awaddr':"32'b0",'awlen':"8'b0",'awsize':"3'd4",'awburst':"2'b01",'awvalid':"1'b0",'wdata':"128'b0",'wstrb':"16'b0",'wlast':"1'b0",'wvalid':"1'b0",'bready':"1'b1"}.items():
            ports.append(f'.{name}_{sig}({val})')
    for sig,val in {'arid':"8'h03",'araddr':"32'h06000000",'arlen':"8'd31",'arsize':"3'd4",'arburst':"2'b01",'arvalid':'rst_n','rready':"1'b1"}.items():
        ports.append(f'.cpu_{sig}({val})')
    for sig,val in {'arid':"8'h01",'araddr':'araddr','arlen':'arlen','arsize':"3'd4",'arburst':"2'b01",'arvalid':'arvalid','arready':'arready','rdata':'rdata','rresp':'rresp','rlast':'rlast','rvalid':'rvalid','rready':'rready'}.items():
        ports.append(f'.vid_{sig}({val})')
    for sig,val in {'awready':"1'b0",'wready':"1'b0",'bid':"4'b0",'bresp':"2'b0",'bvalid':"1'b0",'araddr':'maraddr','arlen':'marlen','arid':'marid','arvalid':'marvalid','arready':'!read_active','rid':'saved_id','rdata':'data_at(address)','rresp':"2'b0",'rlast':'beat==len','rvalid':'mrvalid','rready':'mrready'}.items():
        ports.append(f'.ddr_{sig}({val})')
    bridge=f"axi_shared_ddr_2m #(.DYNAMIC_VIDEO_READ(1'b1),.URGENT_OVERRIDES_FAIRNESS(1'b{int(hard>0)}),.RESERVE_URGENT_READ(1'b{int(hard==2)})) bridge("+','.join(ports)+');\n'
    text=text.replace(' style_display dut(.*);',bridge+' style_display dut(.*);')
    text=text.replace('if(arvalid&&arready)begin','if(marvalid&&!read_active)begin')
    text=text.replace('read_active<=1;address<=araddr;len<=arlen;beat<=0;rhold<=0;ar_count=ar_count+1;', 'read_active<=1;address<=maraddr;len<=marlen;saved_id<=marid;beat<=0;rhold<=0;ar_count=ar_count+1;return_delay<=marid[3] ? 24:320;')
    text=text.replace('if(rvalid&&rready)begin','if(mrvalid&&mrready)begin')
    text=text.replace('   if(block_cycles>0)block_cycles<=block_cycles-1;', '   if(return_delay>0)return_delay<=return_delay-1;')
    text=text.replace('   if(frames==1&&dut.v==310&&!stalled)begin block_cycles<=5000;stalled<=1;end','')
    text=text.replace('       if(frames!=1)$fatal(1,"unexpected starvation frame=%0d row=%0d x=%0d",frames,oldv-145,oldh-260);','')
    text=text.replace('if(frames==3)begin','if(frames==1)begin')
    text=text.replace('       if(bad_pixels==0||dma_errors!=0)$fatal(1,"error recovery");','       if(dma_errors!=0)$fatal(1,"DMA errors");')
    text=text.replace('PASS 720p60 display: 3 full frames, paired slots 2/4, exact RGB, starvation black/recovery,','PASS sustained contention:')
    tb=OUT/f'mode{hard}.sv';tb.write_text(text);sim=OUT/f'mode{hard}.vvp'
    modules=['rtl/style/'+m+'.sv' for m in ('style_display','style_display_beats','style_async_fifo','style_axi_rows')]+['rtl/soc_integration/axi_shared_ddr_2m.sv']
    c=subprocess.run(['C:/iverilog/bin/iverilog.exe','-g2012','-s','style_contention_tb','-o',str(sim),str(tb),*modules],cwd=ROOT,capture_output=True,text=True)
    assert c.returncode==0,c.stderr
    r=subprocess.run(['C:/iverilog/bin/vvp.exe',str(sim)],cwd=ROOT,capture_output=True,text=True,timeout=300)
    (OUT/f'mode{hard}.log').write_text(c.stderr+r.stdout+r.stderr)
    print(f'hard={hard} '+r.stdout,flush=True);assert r.returncode==0,r.stderr
    matched=re.search(r'good=(\d+) underflow=(\d+) bursts=(\d+)',r.stdout)
    results[str(hard)]={key:int(val) for key,val in zip(('good','underflow','bursts'),matched.groups())}
(OUT/'metrics.json').write_text(json.dumps(results,indent=2)+'\n')
assert results['1']['underflow']<=results['0']['underflow'],results
assert results['0']['underflow']>0 and results['2']['underflow']==0,results
