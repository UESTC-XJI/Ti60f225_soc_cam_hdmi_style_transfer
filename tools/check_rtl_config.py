"""Verify this migration against its baseline, including protected byte blocks.

Intentional 720p imports use their pre-migration token fingerprints; other
files retain the original Gamma-removal audit baseline.
This is a migration audit, not a restriction on future intentional RTL changes.
"""
from pathlib import Path
import json
import re
import subprocess
from centralize_rtl_config import ROOT, tokens
from refresh_rtl_config import token_digest

BASELINE = '748553b'

def remove_gamma(source):
    source = re.sub(r'wire \[7:0\] gamma_[rgb]data ;\r?\n|wire gamma_(?:valid|hs|vs|sel);\r?\n', '', source)
    source = re.sub(r'gamma_correction\s*#\([\s\S]*?\n\);', '', source, count=1)
    source = re.sub(r'gamma_sel \? gamma_(vs|hs|valid|rdata|gdata|bdata) : (lift_\w+)', r'\2', source)
    return re.sub(r'\s*\.vio0_gamma_sel\s*\(gamma_sel\),', '', source)

def main():
    git = ['git', '-C', str(ROOT)]
    source = (ROOT / 'rtl/defines.v').read_bytes().decode('latin1')
    entries = re.findall(r'^`define (CFG_\w+) (.*)$', source, re.M)
    definitions = dict(entries)
    assert len(entries) == len(definitions), 'duplicate configuration macro'
    ddr = subprocess.check_output(git + ['show', BASELINE + ':rtl/ddr3_controller/ddr3_parameter.vh'], cwd=ROOT).decode('latin1')
    old_ddr = dict(re.findall(r'^`define (\w+)\s+([^\r\n]+)', ddr, re.M))
    new_ddr = dict(re.findall(r'^`define (\w+)\s+([^\r\n]+)', source, re.M))
    assert all(new_ddr[k].strip() == v.strip() for k, v in old_ddr.items()), 'DDR configuration changed'
    rows = json.loads((ROOT / 'tools/rtl_config_manifest.json').read_text())
    for row in rows:
        name = row['file']
        new = (ROOT / name).read_bytes().decode('latin1')
        new = re.sub(r'^`include "(?:\.\./)*defines\.v"\r?\n', '', new)
        # Fixed widths produce the same bounds; symbolic ranges and defaults
        # must expand to the exact original tokens, in their original scope.
        new = re.sub(r'`CFG_BITS_(\d+)-1', lambda m: str(int(m[1])-1), new)
        new = re.sub(r'`(CFG_\w+)', lambda m: definitions[m[1]], new)
        # The top is an intentional integration point: SoC/AXI/APB/OSD
        # instances and fixed defaults are expected to differ. Keep the
        # protected vendor blocks and DDR configuration checks below.
        if name == 'rtl/ti60f225_oob_top.v':
            old = subprocess.check_output(git + ['show', BASELINE + ':' + name], cwd=ROOT).decode('latin1')
            protected = r'`pragma protect begin_protected[\s\S]*?`pragma protect end_protected'
            assert re.findall(protected, old.replace('\r\n', '\n')) == re.findall(protected, new.replace('\r\n', '\n')), 'protected content modified: ' + name
            continue
        if 'expanded_token_sha256' in row:
            assert token_digest(new) == row['expanded_token_sha256'], 'imported RTL config differs: ' + name
            continue
        old = subprocess.check_output(git + ['show', BASELINE + ':' + name], cwd=ROOT).decode('latin1')
        if name == 'rtl/ti60f225_oob_top.v':
            old = remove_gamma(old)
        a, b = [t[0] for t in tokens(old)], [t[0] for t in tokens(new)]
        assert a == b, 'expanded RTL differs from baseline: ' + name
        protected = r'`pragma protect begin_protected[\s\S]*?`pragma protect end_protected'
        assert re.findall(protected, old.replace('\r\n', '\n')) == re.findall(protected, new.replace('\r\n', '\n')), 'protected content modified: ' + name
    # Removing VIO must retain the measured white balance and manual tone
    # calibration. Equal gains passed the former structural checks but
    # regressed the real camera image to green.
    baseline_debug = json.loads(subprocess.check_output(
        git + ['show', BASELINE + ':debug.json'], cwd=ROOT))
    probes = next(c for c in baseline_debug['debug_cores'] if c['name'] == 'vio0')['probes']
    calibrated = {p['name']: int(p['init'], 0) for p in probes if p['init'] is not None}
    top = (ROOT / 'rtl/ti60f225_oob_top.v').read_text(encoding='latin1')
    removal = (ROOT / 'tools/remove_manual_debug.py').read_text(encoding='utf-8')
    for name in ['r_gain','g_gain','b_gain','tone_enable','high_green_strength',
                 'dark_red_strength','lift_enable','lift_strength']:
        for text in [top, removal]:
            value = re.search(r'\b' + name + r"\s*=\s*\d+'([bdh])([0-9a-fA-F]+)", text)
            assert value, 'missing calibrated control: ' + name
            actual = int(value[2], {'b': 2, 'd': 10, 'h': 16}[value[1]])
            assert actual == calibrated[name], 'baseline camera calibration changed: ' + name
    print('PASS baseline white balance and manual tone calibration survive VIO removal.')
    updated = sum('expanded_token_sha256' in row for row in rows)
    print(f'PASS: {len(rows)} RTL files checked; {updated} intentional 720p imports match their pre-migration tokens; remaining RTL/DDR/encrypted contents match baseline.')

if __name__ == '__main__':
    main()
