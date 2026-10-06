"""Verify this migration against its baseline, including protected byte blocks.

The only behavioral RTL difference allowed is removal of the Gamma path.
This is a migration audit, not a restriction on future intentional RTL changes.
"""
from pathlib import Path
import json
import re
import subprocess
from centralize_rtl_config import ROOT, tokens

BASELINE = '748553b'

def remove_gamma(source):
    source = re.sub(r'wire \[7:0\] gamma_[rgb]data ;\r?\n|wire gamma_(?:valid|hs|vs|sel);\r?\n', '', source)
    source = re.sub(r'gamma_correction\s*#\([\s\S]*?\n\);', '', source, count=1)
    source = re.sub(r'gamma_sel \? gamma_(vs|hs|valid|rdata|gdata|bdata) : (lift_\w+)', r'\2', source)
    return re.sub(r'\s*\.vio0_gamma_sel\s*\(gamma_sel\),', '', source)

def main():
    git_dir = ROOT.parent / 'Ti60f225_soc_cam_hdmi/.git/worktrees' / ROOT.name
    git = ['git', '--git-dir=' + str(git_dir), '--work-tree=' + str(ROOT)]
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
        old = subprocess.check_output(git + ['show', BASELINE + ':' + name], cwd=ROOT).decode('latin1')
        new = (ROOT / name).read_bytes().decode('latin1')
        new = re.sub(r'^`include "(?:\.\./)*defines\.v"\r?\n', '', new)
        if name == 'rtl/ti60f225_oob_top.v':
            old = remove_gamma(old)
        # Fixed widths produce the same bounds; symbolic ranges and defaults
        # must expand to the exact original tokens, in their original scope.
        new = re.sub(r'`CFG_BITS_(\d+)-1', lambda m: str(int(m[1])-1), new)
        new = re.sub(r'`(CFG_\w+)', lambda m: definitions[m[1]], new)
        a, b = [t[0] for t in tokens(old)], [t[0] for t in tokens(new)]
        assert a == b, 'expanded RTL differs from baseline: ' + name
        protected = r'`pragma protect begin_protected[\s\S]*?`pragma protect end_protected'
        assert re.findall(protected, old.replace('\r\n', '\n')) == re.findall(protected, new.replace('\r\n', '\n')), 'protected content modified: ' + name
    print(f'PASS: {len(rows)} RTL files expand to the original tokens; only Gamma removal allowed; encrypted bytes unchanged.')

if __name__ == '__main__':
    main()
