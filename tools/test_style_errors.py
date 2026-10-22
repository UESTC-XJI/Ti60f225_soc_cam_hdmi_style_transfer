"""Injected AXI response errors and asynchronous reset during an active job."""
from pathlib import Path
import subprocess,sys
ROOT=Path(__file__).resolve().parents[1];OUT=ROOT/'reports/style_demo/errors';OUT.mkdir(parents=True,exist_ok=True)
if not (ROOT/'reports/style_demo/accel/tb.sv').exists():
    subprocess.run([sys.executable,'tools/test_style_accel.py'],cwd=ROOT,check=True)
original=(ROOT/'reports/style_demo/accel/tb.sv').read_text()
rtl=['style_accel','style_async_fifo','style_axi_cdc','style_network','style_axi_rows','style_row_core','style_mac8x12']
for kind in ['read_error','write_error','reset']:
    text=original.replace('style_accel_tb','style_errors_tb')
    if kind!='reset':
        text=text.replace('full graph exact RGB','expected AXI error completion/W1C')
        text=text.replace('wire [1:0] rresp=0,bresp=0;',f'wire [1:0] rresp={2 if kind=="read_error" else 0},bresp={2 if kind=="write_error" else 0};')
        text=text.replace('if(error)$fatal(1,"accelerator error");','if(!error)$fatal(1,"missing error completion");')
        text=text.replace('    for(i=0;i<192;i=i+1) if(mem[4096+i]!==golden[i]) $fatal(1,"output beat %0d got=%h expected=%h",i,mem[4096+i],golden[i]);','')
        text=text.replace("write_apb(8'h08,2,0)","write_apb(8'h08,6,0)")
    else:
        text=text.replace("write_apb(8'h10,32'h05140000,1);",'''write_apb(8'h10,32'h05140000,1);
    repeat(400)@(negedge clk);rst_n=0;repeat(7)@(negedge clk);
    if(irq||dut.pending||arvalid||awvalid||wvalid)$fatal(1,"reset did not quiesce bus");
    rst_n=1;repeat(12)@(negedge clk);
    write_apb(8'h18,32'h00180020,0);write_apb(8'h0c,1,0);write_apb(8'h04,1,0);''')
    text=text.replace('PASS style_accel APB+CDC+IRQ',f'PASS style {kind} APB+CDC+IRQ')
    tb=OUT/f'{kind}.sv';tb.write_text(text);sim=OUT/f'{kind}.vvp'
    c=subprocess.run(['C:/iverilog/bin/iverilog.exe','-g2012','-grelative-include','-s','style_errors_tb','-o',str(sim),str(tb),*[f'rtl/style/{m}.sv' for m in rtl]],cwd=ROOT,capture_output=True,text=True);assert c.returncode==0,c.stderr
    r=subprocess.run(['C:/iverilog/bin/vvp.exe',str(sim),'+input='+str(ROOT/'reports/style_demo/accel/input.hex'),'+expected='+str(ROOT/'reports/style_demo/accel/expected.hex')],cwd=ROOT,capture_output=True,text=True,timeout=180)
    (OUT/f'{kind}.log').write_text(c.stderr+r.stdout+r.stderr);print(r.stdout,flush=True);assert r.returncode==0,r.stderr
