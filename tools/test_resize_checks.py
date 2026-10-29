"""Resume the fast integration checks after the full-frame numerical tests."""
from pathlib import Path
import subprocess, os
root=Path(__file__).resolve().parents[1]
IVERILOG=os.environ.get('IVERILOG','C:/iverilog/bin/iverilog.exe')
VVP=os.environ.get('VVP','C:/iverilog/bin/vvp.exe')
out=root/'reports/simulation';out.mkdir(parents=True,exist_ok=True)
log=out/'test.log'
jobs=[
 ('tb_camera_resize',['tests/tb_camera_resize.sv','rtl/resize/camera_raw_gearbox.v','rtl/resize/rgb_area_resize_3to2.v','rtl/debayer/debayer_top_2to1.v','rtl/debayer/rgb_gain_v1.v','rtl/debayer/line_buffer.v','rtl/debayer/raw_to_rgb.v','rtl/true_dual_port_ram.v'],['-Ptb_camera_resize.W=12','-Ptb_camera_resize.H=6','-Ptb_camera_resize.F=3']),
 ('tb_resize_faults',['tests/tb_resize_faults.sv','rtl/resize/camera_raw_gearbox.v','rtl/resize/rgb_area_resize_3to2.v'],[]),
 ('tb_video_dma',['tests/tb_video_dma.sv']+[p.relative_to(root).as_posix() for p in (root/'rtl/frame_buffer_V4').glob('*.v')],[]),
 ('tb_cvo_720p',['tests/tb_cvo_720p.sv','rtl/user_cvo_axi_v2/cvo_axi_v2.v','rtl/frame_buffer_V4/DC_FIFO.v'],[])]
for top,files,opts in jobs:
    sim=out/(top+'_checks.vvp')
    for args in [[IVERILOG,'-g2012','-grelative-include','-I',str(root/'rtl'),'-I',str(root/'rtl/isp'),'-s',top,*opts,'-o',str(sim),*files],[VVP,str(sim)]]:
        p=subprocess.run(args,cwd=root,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=300)
        print(p.stdout,end='',flush=True)
        with log.open('a',encoding='utf-8') as f:f.write(p.stdout)
        if p.returncode:raise RuntimeError(f'{top} failed')
