"""Reproducible local regression; --vga adds the long complete VGA oracle test."""
import argparse, subprocess, sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--vga',action='store_true');p.add_argument('--system',action='store_true');a=p.parse_args()
checks=['test_style_mac','test_style_rows','test_style_network','test_style_accel',
        'test_style_errors','test_style_shared','test_style_ddr_units','test_style_video','build_firmware',
        'test_firmware_runtime','test_style_telemetry','test_style_ddr_firmware','test_camera_3a_runtime',
        'test_resource_optimization','check_rtl_config']
if a.system:checks+=['test_style_system']
if a.vga:checks+=['test_style_vga']
for name in checks:
    print(f'RUN {name}',flush=True)
    subprocess.run([sys.executable,f'tools/{name}.py'],cwd=ROOT,check=True)
print('PASS style deployment regression')
