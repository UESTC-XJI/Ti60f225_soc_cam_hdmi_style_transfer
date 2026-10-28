"""Verify video frame-event CDC, rate windows and APB diagnostics."""
from pathlib import Path
import os
import subprocess

ROOT = Path(__file__).resolve().parents[1]
IVERILOG = Path(os.environ.get('IVERILOG_BIN', 'C:/iverilog/bin'))
OUT = ROOT / 'work/video_frame_diagnostics'
OUT.mkdir(parents=True, exist_ok=True)
logs = []
for top, rtl in [('video_frame_diagnostics_tb', 'video_frame_diagnostics'),
                 ('video_status_counters_tb', 'video_status_counters'),
                 ('osd_apb_regs_tb', 'osd_apb_regs')]:
    binary = OUT / (top + '.vvp')
    subprocess.run([str(IVERILOG / 'iverilog.exe'), '-g2012', '-s', top,
                    '-o', str(binary), 'tests/' + top + '.sv',
                    'rtl/soc_integration/' + rtl + '.sv'], cwd=ROOT, check=True)
    result = subprocess.run([str(IVERILOG / 'vvp.exe'), str(binary)],
                            cwd=ROOT, check=True, capture_output=True, text=True, timeout=120)
    print(result.stdout, end='')
    logs.append(result.stdout)
report = ROOT / 'reports/simulation/video_frame_diagnostics.log'
report.parent.mkdir(parents=True, exist_ok=True)
report.write_text(''.join(logs), encoding='utf-8')
