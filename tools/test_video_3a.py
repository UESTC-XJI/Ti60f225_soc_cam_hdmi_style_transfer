"""Exercise unified APB and capture statistics with the actual BGGR Debayer."""
from pathlib import Path
import subprocess
import sys
ROOT=Path(__file__).resolve().parents[1]
out=ROOT/('work/rtl_checks/video_3a_full.vvp' if '--full' in sys.argv else 'work/rtl_checks/video_3a.vvp')
out.parent.mkdir(parents=True,exist_ok=True)
sources=['tests/video_3a_tb.sv','rtl/soc_integration/video_apb_ctrl.sv',
         'rtl/soc_integration/video_cfg_cdc.sv','rtl/soc_integration/osd_apb_regs.sv',
         'rtl/isp/capture_frame_stats.sv','rtl/isp/isp_cdc_mailbox.v',
         'rtl/debayer/debayer_top_2to1.v','rtl/debayer/rgb_gain_v1.v',
         'rtl/debayer/line_buffer.v','rtl/debayer/raw_to_rgb.v','rtl/true_dual_port_ram.v']
subprocess.run(['C:/iverilog/bin/iverilog.exe','-g2012','-grelative-include','-I','rtl',
                '-s','video_3a_tb','-o',str(out),*(['-Pvideo_3a_tb.W=1920','-Pvideo_3a_tb.H=1080'] if '--full' in sys.argv else []),*sources],cwd=ROOT,check=True)
subprocess.run(['C:/iverilog/bin/vvp.exe',str(out)],cwd=ROOT,check=True,timeout=300)
