"""Synthesis, place-and-route and bitstream for ti60f225_cam_hdmi.xml with Efinity efx_run.

    python3 tools/run_efinity.py                 # full compile: map, interface, pnr, pgm
    python3 tools/run_efinity.py --flow map      # synthesis only
    python3 tools/run_efinity.py --report        # summarise the existing outflow/ only

EFINITY_HOME selects the install (default /home/goodmann/efinity/2026.1, or C:/Efinity/2026.1
on Windows). Work directories come from the project XML (work_syn/, work_pnr/).
Before a pgm run, the previous bitstream is kept as outflow/ti60f225_oob.prev.{bit,hex}.
Exit status is non-zero if a stage fails, the bitstream is not refreshed, or timing has
negative setup/hold slack.
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJECT = 'ti60f225_cam_hdmi.xml'
NAME = 'ti60f225_oob'   # project name inside the XML; prefixes every output file
DEFAULT_HOME = 'C:/Efinity/2026.1' if os.name == 'nt' else '/home/goodmann/efinity/2026.1'


def efx_run_path():
    home = Path(os.environ.get('EFINITY_HOME', DEFAULT_HOME))
    exe = home / 'bin' / ('efx_run.bat' if os.name == 'nt' else 'efx_run')
    if not exe.exists():
        sys.exit(f'efx_run not found at {exe}; set EFINITY_HOME to the Efinity install directory.')
    return exe


def slack_table(text, title):
    """[(launch, capture, slack)] from a 'Clock Relationship' table of the STA report."""
    rows, inside = [], False
    for line in text.splitlines():
        if line.startswith(title):
            inside = True
            continue
        if inside:
            if not line.strip():
                if rows: break
                continue
            parts = line.split()
            if parts[0] == 'Launch': continue
            try:
                rows.append((parts[0], parts[1], float(parts[-2])))
            except (ValueError, IndexError):
                break
    return rows


def report(out):
    """Print resources and timing; return a list of problems."""
    problems = []
    place = out / f'{NAME}.place.rpt'
    if place.exists():
        for line in place.read_text(errors='replace').splitlines():
            if re.match(r'^(XLRs|Memory Blocks|DSP Blocks|Global Clocks \(GBUF\)|Inputs|Outputs):', line):
                print('  ' + line)
    else:
        print(f'  (no {place.name})')

    timing = out / f'{NAME}.timing.rpt'
    if timing.exists():
        text = timing.read_text(errors='replace')
        for title, kind in (('Setup (Max) Clock Relationship', 'setup'), ('Hold (Min) Clock Relationship', 'hold')):
            rows = slack_table(text, title)
            if not rows:
                problems.append(f'no {kind} table in {timing.name}')
                continue
            worst = min(rows, key=lambda r: r[2])
            print(f'  worst {kind:5} slack {worst[2]:7.3f} ns  ({worst[0]} -> {worst[1]})')
            for launch, capture, slack in rows:
                if slack < 0:
                    problems.append(f'{kind} violation {slack:.3f} ns: {launch} -> {capture}')
        fmax = re.search(r'Maximum possible analyzed clocks frequency\n(.*?)\n\n', text, re.S)
        if fmax:
            print('  ' + '\n  '.join(fmax.group(1).splitlines()))
    else:
        print(f'  (no {timing.name})')

    err = out / f'{NAME}.err.log'
    if err.exists():
        lines = [l for l in err.read_text(errors='replace').splitlines() if l.startswith('ERROR')]
        if lines:
            problems += lines[:10]
    return problems


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--flow', default='compile', choices=['compile', 'map', 'interface', 'pnr', 'pgm'],
                    help='efx_run flow (default: compile = map + interface + pnr + pgm)')
    ap.add_argument('--output-dir', default='outflow')
    ap.add_argument('--timeout', type=int, help='overall timeout in seconds')
    ap.add_argument('--report', action='store_true', help='only summarise the existing output directory')
    a = ap.parse_args()

    out = ROOT / a.output_dir
    if a.report:
        problems = report(out)
        for p in problems: print('FAIL', p)
        sys.exit(1 if problems else 0)

    exe = efx_run_path()
    out.mkdir(exist_ok=True)
    bit = out / f'{NAME}.bit'
    if a.flow in ('compile', 'pgm'):
        for ext in ('bit', 'hex'):
            old = out / f'{NAME}.{ext}'
            if old.exists(): shutil.copy2(old, out / f'{NAME}.prev.{ext}')

    cmd = [str(exe), PROJECT, '--flow', a.flow, '--output_dir', a.output_dir]
    if a.timeout: cmd += ['--timeout', str(a.timeout)]
    log = out / f'run_efinity_{a.flow}.log'
    print('RUN', ' '.join(cmd))
    print('LOG', log)
    start = time.time()
    with log.open('w', encoding='utf-8') as f:
        proc = subprocess.Popen(cmd, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, errors='replace')
        for line in proc.stdout:
            f.write(line)
            # Keep the console readable: stage banners, warnings counts and errors only.
            if re.search(r'ERROR|CRITICAL|took .* seconds \[FlowMsg::StageDuration\]$|^Flow ', line):
                sys.stdout.write(line)
        rc = proc.wait()
    minutes = (time.time() - start) / 60
    print(f'efx_run exit {rc} after {minutes:.1f} min')

    problems = [] if rc == 0 else [f'efx_run exit status {rc}; see {log}']
    if a.flow in ('compile', 'pgm') and (not bit.exists() or bit.stat().st_mtime < start):
        problems.append(f'{bit} was not regenerated')
    if a.flow in ('compile', 'pnr', 'pgm'):
        problems += report(out)
    for p in problems: print('FAIL', p)
    if not problems:
        print('PASS', bit if a.flow in ('compile', 'pgm') else a.flow)
    sys.exit(1 if problems else 0)


if __name__ == '__main__':
    main()
