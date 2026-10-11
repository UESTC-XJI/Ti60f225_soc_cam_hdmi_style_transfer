"""Two actual arbitration levels: full ID recovery for CPU, CNN and video."""
from pathlib import Path
import subprocess
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'reports/style_demo/shared';OUT.mkdir(parents=True,exist_ok=True)
widths={'awid':8,'awaddr':32,'awlen':8,'awsize':3,'awburst':2,'awvalid':1,'awready':1,'wdata':128,'wstrb':16,'wlast':1,'wvalid':1,'wready':1,'bid':8,'bresp':2,'bvalid':1,'bready':1,'arid':8,'araddr':32,'arlen':8,'arsize':3,'arburst':2,'arvalid':1,'arready':1,'rid':8,'rdata':128,'rresp':2,'rlast':1,'rvalid':1,'rready':1}
forward=['awid','awaddr','awlen','awsize','awburst','awvalid','wdata','wstrb','wlast','wvalid','bready','arid','araddr','arlen','arsize','arburst','arvalid','rready']
t='''`timescale 1ns/1ps
module style_shared_tb;
reg clk=0,rst_n=0;always #5 clk=~clk;
wire [31:0] errors_inner,errors_outer;
'''
for name,w in widths.items():
    t+=f'wire [{w-1}:0] {name}[0:4];\n'
    if name in forward:
        t+=f'reg [{w-1}:0] m_{name}[0:2];\n'
        for i in range(3):t+=f'assign {name}[{i}]=m_{name}[{i}];\n'
def bridge(name,cpu,vid,dst,idw):
    ports=['.clk(clk)','.rst_n(rst_n)',".allow_access(rst_n)",f'.axi_error_count(errors_{name})']
    for label,idx in [('cpu',cpu),('vid',vid),('ddr',dst)]:
        for sig in widths:
            expr=f'{sig}[{idx}]'
            if label=='ddr' and sig in ['awid','arid','bid','rid']:expr+=f'[{idw-1}:0]'
            ports.append(f'.{label}_{sig}({expr})')
    return f'axi_shared_ddr_2m #(.DDR_ID_W({idw})) {name}('+','.join(ports)+');\n'
t+=bridge('inner',1,2,3,6)+bridge('outer',0,3,4,4)
t+="assign awid[3][7:6]=0;assign arid[3][7:6]=0;assign bid[4][7:4]=0;assign rid[4][7:4]=0;\n"
t+='''reg [31:0] rng=32'h276839af;reg wa=0,ra=0,bv=0,rh=0;
reg [3:0] wi=0,ri=0;integer wp=0,rp=0,wb=0,rb=0;
reg [127:0] mem[0:3071];integer writes=0,reads=0;
assign awready[4]=!wa&&!bv&&rng[0];assign wready[4]=wa&&rng[1];
assign bvalid[4]=bv;assign bid[4][3:0]=wi;assign bresp[4]=0;
assign arready[4]=!ra&&rng[2];assign rvalid[4]=ra&&rh;assign rid[4][3:0]=ri;
assign rdata[4]=mem[rp+rb];assign rresp[4]=0;assign rlast[4]=rb==3;
always @(posedge clk)begin
 rng<={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
 if(awvalid[4]&&awready[4])begin wa<=1;wi<=awid[4];wp<=(awaddr[4]-32'h10000)>>4;wb<=0;end
 if(wvalid[4]&&wready[4])begin
   if(wlast[4]!==(wb==3))$fatal(1,"shared WLAST");mem[wp+wb]<=wdata[4];wb<=wb+1;
   if(wlast[4])begin wa<=0;bv<=1;writes=writes+1;end
 end
 if(bvalid[4]&&bready[4])bv<=0;
 if(arvalid[4]&&arready[4])begin ra<=1;ri<=arid[4];rp<=(araddr[4]-32'h10000)>>4;rb<=0;rh<=0;end
 if(ra&&!rh)rh<=rng[3]||rng[4];
 if(rvalid[4]&&rready[4])begin rh<=0;rb<=rb+1;if(rlast[4])begin ra<=0;reads=reads+1;end end
end
integer finished=0;
task automatic traffic(input integer m);
 integer n,k;reg [7:0] id;reg [127:0] data;
 begin
   id=m==0?8'ha5:m==1?8'hc3:8'he3;
   m_awvalid[m]=0;m_wvalid[m]=0;m_arvalid[m]=0;m_wlast[m]=0;
   m_bready[m]=1;m_rready[m]=1;m_wstrb[m]=16'hffff;
   m_awid[m]=id;m_arid[m]=id;m_awlen[m]=3;m_arlen[m]=3;
   m_awsize[m]=4;m_arsize[m]=4;m_awburst[m]=1;m_arburst[m]=1;
   wait(rst_n);
   for(n=0;n<50;n=n+1)begin
     @(negedge clk);m_awaddr[m]=32'h10000+m*16384+n*64;m_awvalid[m]=1;
     do @(posedge clk);while(!awready[m]);@(negedge clk);m_awvalid[m]=0;
     for(k=0;k<4;k=k+1)begin
       m_wvalid[m]=1;m_wlast[m]=k==3;m_wdata[m]=128'haced0000+m*4096+n*4+k;
       do @(posedge clk);while(!wready[m]);@(negedge clk);m_wvalid[m]=0;
     end
     do @(posedge clk);while(!bvalid[m]);
     if(bid[m]!=id||bresp[m]!=0)$fatal(1,"full write ID m=%0d id=%h",m,bid[m]);
     @(negedge clk);m_araddr[m]=m_awaddr[m];m_arvalid[m]=1;
     do @(posedge clk);while(!arready[m]);@(negedge clk);m_arvalid[m]=0;
     for(k=0;k<4;k=k+1)begin
       do @(posedge clk);while(!rvalid[m]);
       if(rid[m]!=id||rresp[m]!=0||rlast[m]!==(k==3)||rdata[m]!==128'haced0000+m*4096+n*4+k)$fatal(1,"full read/data m=%0d id=%h",m,rid[m]);
       @(negedge clk);
     end
   end
   finished=finished+1;
 end
endtask
initial begin
 fork traffic(0);traffic(1);traffic(2);join
 if(errors_inner||errors_outer||writes!=150||reads!=150)$fatal(1,"shared counts/errors");
 $display("PASS nested AXI: CPU/CNN/video simultaneous traffic, 150 writes+150 reads, full IDs, no starvation");$finish;
end
initial begin repeat(5)@(negedge clk);rst_n=1;end
initial begin #5000000;$fatal(1,"shared timeout");end
endmodule
'''
tb=OUT/'tb.sv';tb.write_text(t);sim=OUT/'test.vvp'
c=subprocess.run(['C:/iverilog/bin/iverilog.exe','-g2012','-s','style_shared_tb','-o',str(sim),str(tb),'rtl/soc_integration/axi_shared_ddr_2m.sv'],cwd=ROOT,capture_output=True,text=True);assert c.returncode==0,c.stderr
r=subprocess.run(['C:/iverilog/bin/vvp.exe',str(sim)],cwd=ROOT,capture_output=True,text=True,timeout=60)
(OUT/'simulation.log').write_text(c.stderr+r.stdout+r.stderr);print(r.stdout);assert r.returncode==0,r.stderr
