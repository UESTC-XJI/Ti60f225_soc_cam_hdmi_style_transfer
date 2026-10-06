"""Regenerate the manual USER1 debugger with Efinity's official RTL generator."""
import json
import os
from pathlib import Path
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]
config_path = ROOT / 'debug.json'
config = json.loads(config_path.read_text(encoding='utf-8'))
vio = next(core for core in config['debug_cores'] if core['name'] == 'vio0')
existing = {probe['name'] for probe in vio['probes']}
added = False
for name, width, initial in [
    ('osd_hist_enable', 1, '0x1'), ('osd_hist_mode', 2, '0x0'), ('osd_text_enable', 1, '0x0'),
    ('osd_hist_valid', 1, None), ('osd_hist_samples', 16, None),
    ('ae_exposure_constrained', 1, None),
    ('lift_auto_enable', 1, '0x1'), ('lift_auto_max', 8, '0x80'),
    ('ae_display_mean', 8, None), ('lift_actual_strength', 8, None), ('lift_at_max', 1, None),
    ('ae_high_protect', 1, '0x1'), ('ae_high_threshold', 8, '0xe8'),
    ('ae_high_limit', 8, '0xa'), ('lift_enable', 1, '0x0'), ('lift_strength', 8, '0x60'),
    ('ae_high_permille', 10, None), ('ae_highlight_limited', 1, None),
]:
    if name not in existing:
        vio['probes'].append({'name': name, 'width': width, 'init': initial})
        added = True
if added:
    vio['uuid'] = uuid.uuid4().hex
efinity = Path(os.environ.get('EFINITY_HOME', 'C:/Efinity/2026.1'))
os.environ['EFXDBG_HOME'] = str(efinity / 'debugger')
os.environ['EFXPGM_HOME'] = str(efinity / 'pgm')
sys.path[:0] = [str(efinity / 'debugger/bin'), str(efinity / 'pgm/bin')]
from efx_dbg.define import DebugProfileDecoder
from efx_dbg.rtl_gen import write_debug_top_verilog
profile = json.loads(json.dumps(config), cls=DebugProfileDecoder)
write_debug_top_verilog(str(ROOT / 'debug_top.v'), profile, 'debug_edb_top', insert_gbuf=True)
config_path.write_text(json.dumps(config, indent=4) + '\n', encoding='utf-8')
print('Generated manual USER1 debugger: highlight protection and automatic tone lift.')

# The CLI compile flow consumes this generated core but does not create it.
# Keep the existing automatic USER2 MIPI analyzer available in a clean checkout.
from efx_dbg.DbgWizard import DbgWizardContext, generate_wizard_debugger_profile
auto_dir = ROOT / 'work_dbg'
auto_dir.mkdir(exist_ok=True)
auto_path = ROOT / 'debug_profile.wizard.json'
auto_profile = generate_wizard_debugger_profile(
    DbgWizardContext(str(auto_path)), out_profile_path=auto_path,
    out_dbg_vdb=auto_dir / 'debug_top.post.vdb')
write_debug_top_verilog(str(auto_dir / 'debug_top.v'), auto_profile, 'edb_top', insert_gbuf=True)
print('Generated automatic USER2 MIPI analyzer in work_dbg.')
