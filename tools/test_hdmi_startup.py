"""Check full 720p startup timing, source handover and the APB CPU gate."""
from pathlib import Path
import os
import subprocess

ROOT = Path(__file__).resolve().parents[1]
IVERILOG = Path(os.environ.get('IVERILOG_BIN', 'C:/iverilog/bin'))
OUT = ROOT / 'work/hdmi_startup'
OUT.mkdir(parents=True, exist_ok=True)
logs = []
for top, sources in [
    ('hdmi_startup_colorbar_tb', ['tests/hdmi_startup_colorbar_tb.sv',
                                'rtl/soc_integration/hdmi_startup_colorbar.sv']),
    ('hdmi_startup_select_tb', ['tests/hdmi_startup_colorbar_tb.sv',
                              'rtl/soc_integration/hdmi_startup_colorbar.sv']),
    ('osd_apb_regs_tb', ['tests/osd_apb_regs_tb.sv', 'rtl/soc_integration/osd_apb_regs.sv']),
]:
    binary = OUT / (top + '.vvp')
    subprocess.run([str(IVERILOG / 'iverilog.exe'), '-g2012', '-s', top,
                    '-o', str(binary), *sources], cwd=ROOT, check=True)
    result = subprocess.run([str(IVERILOG / 'vvp.exe'), str(binary)],
                            cwd=ROOT, check=True, capture_output=True, text=True, timeout=120)
    print(result.stdout, end='')
    logs.append(result.stdout)
report = ROOT / 'reports/simulation/hdmi_startup.log'
report.parent.mkdir(parents=True, exist_ok=True)
report.write_text(''.join(logs), encoding='utf-8')
