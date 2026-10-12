"""Actual integrated CNN/capture/display/bridge under simultaneous DDR traffic.

Preload a complete immutable display pair in slot0, infer a configurable-height
VGA job in slot1, and feed one 1080p camera frame into slot2. Short jobs measure
an active-display interval; none of these tests measures physical DDR FPS.
"""
from pathlib import Path
import subprocess,re,json,time,sys,argparse,hashlib
parser=argparse.ArgumentParser();parser.add_argument('--variant',choices=['baseline','buffer','adaptive'],default='adaptive');parser.add_argument('--height',type=int,default=48);parser.add_argument('--tag',default='');args=parser.parse_args()
assert 24<=args.height<=480 and args.height%4==0
assert not args.tag or re.fullmatch(r'[a-z0-9_]+',args.tag)
ROOT=Path(__file__).resolve().parents[1];suffix='' if args.height==48 else f'_vga{args.height}';suffix+=f'_{args.tag}' if args.tag else '';OUT=ROOT/f'reports/style_demo/ddr_optimization/{args.variant}{suffix}';OUT.mkdir(parents=True,exist_ok=True)
fixture=ROOT/f'reports/style_demo/vga_{args.height}'
if not all((fixture/name).exists() for name in ['input.hex','expected.hex']):
    subprocess.run([sys.executable,'tools/test_style_vga.py','--height',str(args.height),'--fixtures-only'],cwd=ROOT,check=True)
if not (ROOT/'reports/style_demo/accel/tb.sv').exists():
    subprocess.run([sys.executable,'tools/test_style_accel.py'],cwd=ROOT,check=True)
text=(ROOT/'reports/style_demo/accel/tb.sv').read_text()
text=text.replace('style_accel_tb','style_system_tb').replace('dut.','dut.accelerator.')
beats=640*args.height//4
text=text.replace('frame_width=32,frame_height=24',f'frame_width=640,frame_height={args.height}')
text=text.replace('mem[0:24575],golden[0:191]',f'mem[0:1310719],golden[0:{beats-1}]')
start=text.index('      if(address>=');end=text.index('\n    end\n  endfunction',start)
text=text[:start]+'''      if(address>=32'h05000000 && address<32'h05800000) address_index=(address-32'h05000000)>>4;
      else if(address>=32'h05800000 && address<32'h06000000) address_index=524288+((address-32'h05800000)>>4);
      else if(address>=32'h06000000 && address<32'h06400000) address_index=1048576+((address-32'h06000000)>>4);
      else begin address_index=0;$fatal(1,"illegal DDR address %h",address);end'''+text[end:]
text=text.replace('style_accel dut(.*);','''reg pix_clk=0;always #6.734 pix_clk=~pix_clk;
  reg rgb_vs=0,rgb_de=0;reg [47:0] rgb_data=0;
  wire [31:0] pixel,resized_frames;wire hs,vs,de,underflow,capture_fault;
  wire [5:0] awid,arid;reg [5:0] bid=0,rid=0;wire [2:0] awsize,arsize;wire [1:0] awburst,arburst;
  style_video_system dut(.*);
  integer display_pixels=0,underflows=0,capture_beats=0;
  integer ph,pv;
  always @(posedge pix_clk)if(rst_n)begin
    ph=dut.display.h;pv=dut.display.v;#1;
    if(pv>=145&&pv<625&&ph>=260&&ph<1540)begin
      display_pixels=display_pixels+1;
      if(underflow)underflows=underflows+1;
      else if(pixel!==(ph<900 ? 32'h00221100:32'h00332211))$fatal(1,"immutable display pair corrupted");
    end
  end
  initial begin
    wait(dut.accelerator.pending);
    @(negedge cnn_clk);rgb_vs=1;repeat(4)@(negedge cnn_clk);rgb_vs=0;repeat(3)@(negedge cnn_clk);
    for(integer yy=0;yy<1080;yy=yy+1)begin
      for(integer xx=0;xx<960;xx=xx+1)begin rgb_de=1;rgb_data=48'h030201030201;@(negedge cnn_clk);end
      rgb_de=0;repeat(40)@(negedge cnn_clk);
    end
  end''')
text=text.replace('assign done=job_done','assign done=dut.accelerator.job_done').replace('assign error=job_error','assign error=dut.accelerator.job_error')
text=text.replace('assign cycles=last_cycles','assign cycles=dut.accelerator.last_cycles')
text=text.replace("source_address=32'h05000000,result_address=32'h05800000", "source_address=32'h05140000,result_address=32'h05940000")
text=text.replace('$readmemh(ifile,mem,0,191);$readmemh(efile,golden,0,191);', '''for(i=0;i<76800;i=i+1)begin
      mem[i]=128'h00221100002211000022110000221100;
      mem[524288+i]=128'h00332211003322110033221100332211;
    end
    $readmemh(ifile,mem,81920,89599);$readmemh(efile,golden,0,7679);'''.replace('89599',str(81920+beats-1)).replace('7679',str(beats-1)))
text=text.replace("write_apb(8'h10,32'h05000000,0);", "write_apb(8'h10,32'h05140000,0);write_apb(8'h14,32'h05940000,0);")
text=text.replace("32'h00180020", f"32'h{(args.height<<16)|640:08x}")
text=text.replace('rst_n=1;', '''rst_n=1;
    // Seed a prior complete display pair before the first display request.
    dut.store.display_valid=1;dut.store.display_slot=0;dut.store.ownership[0]=5;
    dut.store.infer_active=1;dut.store.infer_slot=1;dut.store.ownership[1]=3;
    ''')
text=text.replace("write_apb(8'h04,1,0);", "write_apb(8'h04,17,0);")
text=text.replace("dut.accelerator.source_cfg!=32'h05000000", "dut.accelerator.source_cfg!=32'h05140000")
text=text.replace('i<192',f'i<{beats}').replace('mem[4096+i]','mem[606208+i]')
text=text.replace('read_active<=1;read_addr<=araddr;', 'rid<=arid;read_active<=1;read_addr<=araddr;')
text=text.replace('write_active<=1;write_addr<=awaddr;', 'bid<=awid;write_active<=1;write_addr<=awaddr;')
text=text.replace('if(wvalid&&wready) begin','if(wvalid&&wready) begin\n        if(write_addr>=32\'h05280000&&write_addr<32\'h053c0000)capture_beats=capture_beats+1;')
text=text.replace('n>2000000','n>20000000')
text=text.replace('integer n=0,','reg [4:0] previous_layer=31;\n  integer n=0,')
text=text.replace('      n=n+1;', '''      n=n+1;
      if(dut.accelerator.network.busy&&dut.accelerator.network.layer_index!=previous_layer)begin
        previous_layer<=dut.accelerator.network.layer_index;
        $display("NETWORK layer=%0d total_cycles=%0d",dut.accelerator.network.layer_index,dut.accelerator.network.cycles);
        $fflush();
      end''')
text=text.replace('    $display("PASS', '''    if(capture_fault||underflows||display_pixels<100000||capture_beats!=76800||dut.store.captured!=1)$fatal(1,"concurrent system coverage/fault cap=%0d pix=%0d underflow=%0d",capture_beats,display_pixels,underflows);
    for(i=0;i<76800;i=i+1)if(mem[163840+i]!==128'h00030201000302010003020100030201)$fatal(1,"camera frame beat %0d corrupted",i);
    write_apb(8'h54,1,0);
    for(i=0;i<12;i=i+1)begin
      @(negedge clk);psel=1;penable=1;pwrite=0;paddr=8'h58+i*4;
      @(posedge clk);#1;
      $display("PROFILE %0d %0d",i,prdata);
      if(prdata!==dut.profiler.counters[i])$fatal(1,"profile APB decode");
      @(negedge clk);psel=0;penable=0;
    end
    $display("PHASE read_cycles=%0d compute_cycles=%0d",dut.accelerator.read_cycles_snapshot,dut.accelerator.compute_cycles_snapshot);
    $display("SYSTEM display_pixels=%0d capture_beats=%0d underflows=%0d",display_pixels,capture_beats,underflows);
    $display("PASS''')
text=text.replace('32x24 full graph exact RGB',f'integrated 640x{args.height} exact RGB + active 720p display + camera capture')
text=text.replace('style_video_system dut(.*);',f"style_video_system #(.DISPLAY_BUFFER(1'b{int(args.variant!='baseline')}),.ADAPTIVE_READ(1'b{int(args.variant=='adaptive')})) dut(.*);")
tb=OUT/'tb.sv';tb.write_text(text);sim=OUT/'test.vvp'
modules=[p.relative_to(ROOT).as_posix() for p in (ROOT/'rtl/style').glob('*.sv')]+['rtl/soc_integration/axi_shared_ddr_2m.sv']
rtl_sha256={name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in modules}
c=subprocess.run(['C:/iverilog/bin/iverilog.exe','-g2012','-grelative-include','-s','style_system_tb','-o',str(sim),str(tb),*modules],cwd=ROOT,capture_output=True,text=True);assert c.returncode==0,c.stderr
t=time.monotonic()
with (OUT/'simulation.log').open('w') as log:
    log.write(c.stderr);log.flush()
    r=subprocess.run(['C:/iverilog/bin/vvp.exe',str(sim),'+input='+str(fixture/'input.hex'),'+expected='+str(fixture/'expected.hex')],cwd=ROOT,stdout=log,stderr=log,timeout=5400)
result=(OUT/'simulation.log').read_text();print(result[-2000:]);assert r.returncode==0
cycles=int(re.search(r'^PASS .*\bcycles=(\d+)',result,re.M)[1]);coverage=re.search(r'display_pixels=(\d+) capture_beats=(\d+) underflows=(\d+)',result)
names=['ticks','cnn_ar_wait','downstream_ar_wait','cnn_return_gap','cnn_r_backpressure','display_r_backpressure','cnn_aw_wait','cnn_w_wait','cnn_b_wait','network_idle','cnn_read_beats','display_read_beats']
stats={names[int(i)]:int(v) for i,v in re.findall(r'PROFILE (\d+) (\d+)',result)}
phase=re.search(r'PHASE read_cycles=(\d+) compute_cycles=(\d+)',result)
(OUT/'metrics.json').write_text(json.dumps({'variant':args.variant,'tag':args.tag,'rtl_sha256':rtl_sha256,'width':640,'height':args.height,'cycles':cycles,'milliseconds':cycles/148500,'display_pixels':int(coverage[1]),'capture_beats':int(coverage[2]),'captured_frame_exact_pixels':307200,'underflows':int(coverage[3]),'counters_100mhz':stats,'phase_148_5mhz':{'read_cycles':int(phase[1]),'compute_cycles':int(phase[2])},'profile':f'real integrated RTL; prepared display slot0, 640x{args.height} job slot1, one dense 1080p camera frame into slot2; randomized DDR stalls; no external CPU or DDR PHY model','wall_seconds':time.monotonic()-t},indent=2))
