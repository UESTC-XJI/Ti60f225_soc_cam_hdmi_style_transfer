"""Bit-exact area-overlap reference and asynchronous capture integration tests."""
from pathlib import Path
import random, subprocess, os
root=Path(__file__).resolve().parents[1]
IVERILOG=os.environ.get('IVERILOG','C:/iverilog/bin/iverilog.exe')
VVP=os.environ.get('VVP','C:/iverilog/bin/vvp.exe')
out=root/'reports/simulation';out.mkdir(parents=True,exist_ok=True)
logs=[]
def run(args, timeout=300):
    p=subprocess.run(args,cwd=root,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout)
    print(p.stdout,end='',flush=True);logs.append(p.stdout)
    (out/'test.log').write_text(''.join(logs),encoding='utf-8')
    if p.returncode: raise RuntimeError(f'command failed: {args}')
def vector_test(w,h,f):
    rng=random.Random(0x720)
    src=[]
    for frame in range(f):
        for y in range(h):
            for x in range(w):
                if frame==0: p=rng.randrange(1<<24)
                elif frame==1: p=0xffffff
                elif frame==2: p=0
                elif frame==3: p=0xffffff if (x+y)%2 else 0
                elif frame==4: p=((x*17)%256)|(((y*29)%256)<<8)|(((x+y)*13%256)<<16)
                else: p=0xffffff if x==(frame-5)%w and y==(frame-5)%h else 0
                src.append(p)
    expected=[]
    # Geometrical reference: coordinates in half-source-pixel units;
    # each output covers a 3x3 square; overlap with input 2x2 squares.
    for frame in range(f):
        for oy in range(h*2//3):
            for ox in range(w*2//3):
                channels=[0,0,0]
                for iy in range(oy*3//2,(oy*3+2)//2+1):
                    wy=max(0,min(oy*3+3,iy*2+2)-max(oy*3,iy*2))
                    for ix in range(ox*3//2,(ox*3+2)//2+1):
                        wx=max(0,min(ox*3+3,ix*2+2)-max(ox*3,ix*2))
                        p=src[frame*w*h+iy*w+ix]
                        for c in range(3): channels[c]+=((p>>(c*8))&255)*wx*wy
                expected.append(sum(((v+4)//9)<<(8*c) for c,v in enumerate(channels)))
    sp=out/f'src_{w}.hex';ep=out/f'exp_{w}.hex'
    sp.write_text(''.join(f'{p:06x}\n' for p in src));ep.write_text(''.join(f'{p:08x}\n' for p in expected))
    sim=out/f'area_{w}.vvp'
    run([IVERILOG,'-g2012','-grelative-include','-I',str(root/'rtl'),'-I',str(root/'rtl/isp'),'-s','tb_area_resize',f'-Ptb_area_resize.W={w}',f'-Ptb_area_resize.H={h}',f'-Ptb_area_resize.F={f}','-o',str(sim),'tests/tb_area_resize.sv','rtl/resize/rgb_area_resize_3to2.v'])
    run([VVP,str(sim),f'+src={sp.as_posix()}',f'+exp={ep.as_posix()}'])
try:
    vector_test(18,12,10)
    vector_test(1920,1080,1)
    sim=out/'camera.vvp'
    run([IVERILOG,'-g2012','-grelative-include','-I',str(root/'rtl'),'-I',str(root/'rtl/isp'),'-s','tb_camera_resize','-o',str(sim),'tests/tb_camera_resize.sv','rtl/resize/camera_raw_gearbox.v','rtl/resize/rgb_area_resize_3to2.v','rtl/debayer/debayer_top_2to1.v','rtl/debayer/rgb_gain_v1.v','rtl/debayer/line_buffer.v','rtl/debayer/raw_to_rgb.v','rtl/true_dual_port_ram.v'])
    run([VVP,str(sim)], timeout=1200)
    for top,files in [
        ('tb_resize_faults',['tests/tb_resize_faults.sv','rtl/resize/camera_raw_gearbox.v','rtl/resize/rgb_area_resize_3to2.v']),
        ('tb_video_dma',['tests/tb_video_dma.sv']+ [p.relative_to(root).as_posix() for p in (root/'rtl/frame_buffer_V4').glob('*.v')]),
        ('tb_cvo_720p',['tests/tb_cvo_720p.sv','rtl/user_cvo_axi_v2/cvo_axi_v2.v','rtl/frame_buffer_V4/DC_FIFO.v'])]:
        sim=out/(top+'.vvp')
        run([IVERILOG,'-g2012','-grelative-include','-I',str(root/'rtl'),'-I',str(root/'rtl/isp'),'-s',top,'-o',str(sim)]+files)
        run([VVP,str(sim)])
finally:
    (out/'test.log').write_text(''.join(logs),encoding='utf-8')
