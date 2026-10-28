"""Frame queue and native 720p display verification."""
from pathlib import Path
import subprocess
ROOT=Path(__file__).resolve().parents[1]
out=ROOT/'reports/style_demo/video';out.mkdir(parents=True,exist_ok=True)
for top,modules in [('style_video_tb',['style_vga_crop','style_frame_store']),('style_capture_tb',['style_vga_crop','style_async_fifo','style_frame_store']),('style_display_tb',['style_display','style_display_beats','style_async_fifo','style_axi_rows'])]:
    sim=out/f'{top}.vvp'
    c=subprocess.run(['C:/iverilog/bin/iverilog.exe','-g2012','-s',top,'-o',str(sim),f'tests/{top}.sv',*[f'rtl/style/{m}.sv' for m in modules]],cwd=ROOT,capture_output=True,text=True)
    assert c.returncode==0,c.stderr
    r=subprocess.run(['C:/iverilog/bin/vvp.exe',str(sim)],cwd=ROOT,capture_output=True,text=True,timeout=300)
    (out/f'{top}.log').write_text(c.stderr+r.stdout+r.stderr);print(r.stdout,flush=True);assert r.returncode==0,r.stderr
