"""Generate the compact USER2 debugger with the official Efinity generator.

Run with C:/Efinity/2026.1/python311/bin/python.exe.  The CPU owns USER1.
"""
import json
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
EFINITY = Path(os.environ.get('EFINITY_HOME', 'C:/Efinity/2026.1'))
os.environ['EFXDBG_HOME'] = str(EFINITY / 'debugger')
os.environ['EFXPGM_HOME'] = str(EFINITY / 'pgm')
sys.path[:0] = [str(EFINITY / 'debugger/bin'), str(EFINITY / 'pgm/bin')]
from efx_dbg.rtl_gen import write_debug_top_verilog
from efx_dbg.DbgWizard import DbgWizardContext, generate_wizard_debugger_profile

path = ROOT / 'debug_profile.wizard.json'
config = json.loads(path.read_text(encoding='utf-8'))
wizard = config['session']['wizard']
names = ['w_mipi_rx_hs', 'w_mipi_rx_vs', 'w_mipi_rx_de',
         'mdebug_receive_error', 'mdebug_frame_vc0_error', 'cal_done']
wizard['data_depth'] = 512
wizard['jtag_user'] = 'USER2'
wizard['selected_nets'] = [dict(name=n, width=1, clk_domain='i_mipi_rx_pclk',
    selected_probe_type='DATA AND TRIGGER', child=[], path=[]) for n in names]
path.write_text(json.dumps(config, indent=4)+'\n', encoding='utf-8')
directory = ROOT / 'work_dbg'
directory.mkdir(exist_ok=True)
profile = generate_wizard_debugger_profile(DbgWizardContext(str(path)),
    out_profile_path=path, out_dbg_vdb=directory / 'debug_top.post.vdb')
write_debug_top_verilog(str(directory / 'debug_top.v'), profile, 'edb_top', insert_gbuf=True)
print('Generated USER2 analyzer: 6 one-bit probes, depth 512; USER1 reserved for CPU.')
