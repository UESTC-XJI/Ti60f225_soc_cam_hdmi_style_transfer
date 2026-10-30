"""Run the B mainline APB/FPS control regression with Icarus Verilog."""
from pathlib import Path
import os,subprocess
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'reports/simulation/peripheral_merge'
OUT.mkdir(parents=True,exist_ok=True)
compile_cmd=[os.environ.get('IVERILOG','iverilog'),'-g2012','-I','rtl/isp','-I','rtl','-s','qse_mainline_ui_tb','-o',str(OUT/'ui.vvp'),'tests/qse_mainline_ui_tb.sv','rtl/soc_integration/video_apb_ctrl.sv','rtl/soc_integration/video_cfg_cdc.sv','rtl/isp/isp_cdc_mailbox.v','rtl/accel_rowpipe/fps_overlay.sv']
subprocess.run(compile_cmd,cwd=ROOT,check=True)
result=subprocess.run([os.environ.get('VVP','vvp'),str(OUT/'ui.vvp')],cwd=ROOT,check=True,capture_output=True,text=True,timeout=30)
(OUT/'ui_rtl.log').write_text(result.stdout+result.stderr)
print(result.stdout)
