"""Backup a VERIFIED bitstream with a stable, self-describing name and a manifest.

Rationale (from the user): every time a build is verified on hardware, archive
the bitstream and annotate it, so later work does not have to re-synthesize.

Convention
----------
  reports/ukiyoe/releases/<tag>/
      <tag>.bit            the exact bitstream that was flashed
      <tag>.hex            the SPI image (what ftdi_program.py consumes)
      <tag>_fw.bin         the firmware .bin that was loaded over OpenOCD
      MANIFEST.json        hashes, sources, verification evidence

`taggings` are ordered by the date and a short slug, e.g. 20261017_single_panel.
Only VERIFIED builds get archived; the manifest records the evidence so a later
reader can tell a verified build from a merely-synthesised one.

Usage
-----
  python tools/archive_release.py --tag 20261017_single_panel \
      --bit outflow_nosplit/ti60f225_oob.bit \
      --fw  reports/ukiyoe/firmware/soc_video_app_v15.bin \
      --uart-note "DISP 60 ERR 0 CSI 0 AXI 0" \
      --note "dual-panel display removed: single read per row"
"""
import argparse
import hashlib
import json
import pathlib
import shutil
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
REL = ROOT / 'reports' / 'ukiyoe' / 'releases'


def sha256(p):
    return hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()


def git_rev():
    try:
        out = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=ROOT,
                             capture_output=True, text=True)
        dirty = subprocess.run(['git', 'status', '--porcelain'], cwd=ROOT,
                               capture_output=True, text=True).stdout.strip()
        return out.stdout.strip(), bool(dirty)
    except Exception:
        return None, None


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--tag', required=True,
                   help='release tag, e.g. 20261017_single_panel')
    p.add_argument('--bit', required=True, help='verified .bit to archive')
    p.add_argument('--hex', default='', help='SPI .hex image (optional)')
    p.add_argument('--fw', default='', help='firmware .bin that was loaded')
    p.add_argument('--uart-note', default='',
                   help='the UART evidence string seen on hardware')
    p.add_argument('--note', default='', help='what changed in this build')
    p.add_argument('--force', action='store_true')
    a = p.parse_args()

    bit = (ROOT / a.bit) if not pathlib.Path(a.bit).is_absolute() else pathlib.Path(a.bit)
    if not bit.exists():
        print('MISSING bitstream: %s' % bit)
        sys.exit(1)
    out = REL / a.tag
    if out.exists() and not a.force:
        print('release %s already exists (use --force to overwrite)' % a.tag)
        sys.exit(1)
    out.mkdir(parents=True, exist_ok=True)

    shutil.copy2(bit, out / (a.tag + '.bit'))
    entries = {'bitstream': {'file': a.tag + '.bit', 'sha256': sha256(bit),
                             'bytes': bit.stat().st_size}}

    hexp = (ROOT / a.hex) if a.hex and not pathlib.Path(a.hex).is_absolute() else (
        pathlib.Path(a.hex) if a.hex else None)
    if hexp and hexp.exists():
        shutil.copy2(hexp, out / (a.tag + '.hex'))
        entries['spi_image'] = {'file': a.tag + '.hex',
                                'sha256': sha256(hexp), 'bytes': hexp.stat().st_size}

    fwp = (ROOT / a.fw) if a.fw and not pathlib.Path(a.fw).is_absolute() else (
        pathlib.Path(a.fw) if a.fw else None)
    if fwp and fwp.exists():
        shutil.copy2(fwp, out / (a.tag + '_fw.bin'))
        entries['firmware'] = {'file': a.tag + '_fw.bin',
                               'sha256': sha256(fwp), 'bytes': fwp.stat().st_size}

    rev, dirty = git_rev()
    manifest = {
        'tag': a.tag,
        'archived': time.strftime('%Y-%m-%dT%H:%M:%S%z'),
        'note': a.note,
        'verification': {
            'on_hardware': bool(a.uart_note),
            'uart_evidence': a.uart_note or None,
        },
        'artifacts': entries,
        'git': {'revision': rev, 'working_tree_dirty': dirty},
        'how_to_flash': (
            'python tools/flash_release.py --tag %s' % a.tag),
    }
    (out / 'MANIFEST.json').write_text(json.dumps(manifest, indent=2) + '\n')

    print('archived release: %s' % out.relative_to(ROOT))
    for k, v in entries.items():
        print('  %-12s %-28s %8d B  %s'
              % (k, v['file'], v['bytes'], v['sha256'][:16]))
    print('  verified on hardware: %s' % ('yes' if a.uart_note else 'NOT RECORDED'))
    if not a.uart_note:
        print('  WARNING: no UART evidence recorded; this is a synthesised build '
              'only, not a verified one.')


if __name__ == '__main__':
    main()
