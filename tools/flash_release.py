"""Flash an ARCHIVED release by tag: bitstream over JTAG + firmware over OpenOCD.

Reads reports/ukiyoe/releases/<tag>/MANIFEST.json, verifies the stored SHA256 of
each artifact, then programs the board.  This is the whole point of the archive:
a verified build can be re-deployed without re-synthesising.

Steps (per the ti60f225-flash-debug skill):
  1. ftdi_program.py -m jtag          program <tag>.bit
  2. openocd from software/firmware/openocd   load_image <tag>_fw.bin at 0x1000
  3. verify the loaded word and resume

Usage
-----
  python tools/flash_release.py --tag 20261017_single_panel            # do it
  python tools/flash_release.py --tag ... --dry-run                   # check only
"""
import argparse
import hashlib
import json
import pathlib
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
REL = ROOT / 'reports' / 'ukiyoe' / 'releases'
EFINITY = pathlib.Path('D:/Efinity/2026.1')
FTDI = EFINITY / 'pgm' / 'bin' / 'efx_pgm' / 'ftdi_program.py'
OCD = EFINITY / 'debugger' / 'openocd' / 'bin' / 'openocd.exe'
OCD_WORK = ROOT / 'software' / 'firmware' / 'openocd'
CFG1 = ROOT / 'software' / 'bsp' / 'EfxSapphireSoc' / 'openocd' / 'ftdi_ti.cfg'
CFG2 = ROOT / 'software' / 'bsp' / 'EfxSapphireSoc' / 'openocd' / 'debug_ti.cfg'
# FTDI URL is re-enumerated whenever the cable is replugged; probe it.
FTDI_URL = 'ftdi://0x0403:0x6011:3:3/2'


def sha256(p):
    return hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()


def detect_url():
    """Ask jtag_chain_detect for the live FTDI URL; fall back to the stored one.

    The cable re-enumerates when replugged (COM18 -> COM11/12 were seen), and the
    URL's bus:address fields change with it, so always probe before programming.
    """
    cmd = ('call "%s" && set EFINITY_USER_DIR=C:/Users/36040/.efinity&& '
           'python "%s"' % (EFINITY / 'bin' / 'setup.bat',
                            EFINITY / 'pgm' / 'bin' / 'jtag_chain_detect.py'))
    r = subprocess.run(['cmd.exe', '/c', cmd], cwd=ROOT,
                       capture_output=True, text=True)
    for line in (r.stdout or '').splitlines():
        if 'ftdi://' in line:
            rest = line.split('ftdi://', 1)[1].strip()
            token = rest.split()[0]           # e.g. 0x0403:0x6011:3:3/2
            return 'ftdi://' + token
    return FTDI_URL


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--tag', required=True)
    p.add_argument('--skip-firmware', action='store_true',
                   help='program the bitstream only')
    p.add_argument('--dry-run', action='store_true',
                   help='verify the archive and print the plan, do not touch the board')
    a = p.parse_args()

    d = REL / a.tag
    mf = d / 'MANIFEST.json'
    if not mf.exists():
        print('no such release: %s' % d)
        sys.exit(1)
    man = json.loads(mf.read_text())
    print('release   : %s' % man['tag'])
    print('archived  : %s' % man['archived'])
    print('note      : %s' % (man.get('note') or '-'))
    print('verified  : %s' % ('yes' if man['verification']['on_hardware']
                              else 'NOT RECORDED'))
    if man['verification'].get('uart_evidence'):
        print('uart      : %s' % man['verification']['uart_evidence'])
    print()

    bit = d / man['artifacts']['bitstream']['file']
    bad = []
    for key, info in man['artifacts'].items():
        f = d / info['file']
        if not f.exists():
            bad.append('%s missing' % info['file'])
            continue
        got = sha256(f)
        ok = got == info['sha256']
        print('  %-12s %s %s' % (key, 'OK  ' if ok else 'FAIL', info['file']))
        if not ok:
            bad.append('%s hash mismatch (stored %s, got %s)'
                       % (info['file'], info['sha256'][:12], got[:12]))
    if bad:
        print()
        for b in bad:
            print('  !! %s' % b)
        sys.exit(1)
    print()
    print('  all artifact hashes match the manifest')

    fwp = None
    if not a.skip_firmware and 'firmware' in man['artifacts']:
        fwp = d / man['artifacts']['firmware']['file']

    print()
    print('PLAN')
    print('  1. ftdi_program.py -m jtag  <- %s' % bit.name)
    if fwp:
        print('  2. openocd load_image      <- %s at 0x1000' % fwp.name)
    else:
        print('  2. (skipped)')
    if a.dry_run:
        print()
        print('dry run: nothing was programmed')
        return

    # --- 1. bitstream -------------------------------------------------------
    print()
    print('== programming bitstream ==')
    cmd = ('call "%s" && set EFINITY_USER_DIR=C:/Users/36040/.efinity&& '
           'set EFINITY_USER_DIR_INI=C:/Users/36040/AppData/Local/Efinity/user_dir.ini&& '
           'set PYTHONPATH=%s\\debugger\\bin;%s\\pgm\\bin&& python "%s" -m jtag -u %s '
           '--jtag_clock_freq 1000000 "%s"'
           % (EFINITY / 'bin' / 'setup.bat', EFINITY, EFINITY, FTDI, FTDI_URL, bit))
    r = subprocess.run(['cmd.exe', '/c', cmd], cwd=ROOT,
                       capture_output=True, text=True)
    out = (r.stdout or '') + (r.stderr or '')
    print(out.strip()[-800:])
    if 'finished with JTAG programming' not in out:
        print('!! bitstream programming did not report success')
        sys.exit(1)
    print('  bitstream programmed')
    time.sleep(6)          # let DDR calibration settle

    if not fwp:
        return

    # --- 2. firmware --------------------------------------------------------
    print()
    print('== loading firmware ==')
    subprocess.run(['powershell', '-NoProfile', '-Command',
                    'Get-Process openocd -ErrorAction SilentlyContinue | Stop-Process -Force'],
                   cwd=ROOT)
    time.sleep(2)
    win = fwp.as_posix()      # forward slashes: TCL eats backslashes silently
    r = subprocess.run([str(OCD), '-f', str(CFG1), '-f', str(CFG2),
                        '-c', 'init', '-c', 'reset halt',
                        '-c', 'load_image "%s" 0x1000 bin' % win,
                        '-c', 'mdw 0x1000 4',
                        '-c', 'reg pc 0x00001000', '-c', 'resume',
                        '-c', 'shutdown'],
                       cwd=str(OCD_WORK), capture_output=True, text=True)
    out = (r.stdout or '') + (r.stderr or '')
    print(out.strip()[-900:])
    if 'bytes written at address 0x00001000' not in out:
        print('!! firmware did not report "bytes written"; NOT resuming blindly')
        sys.exit(1)
    print('  firmware loaded and CPU resumed')
    print()
    print('Read UART next (115200 8N1) and expect:')
    print('  DDR scratch PASS')
    print('  MONET CAP .. NN .. DISP 60 DROP .. MS .. ERR 0')


if __name__ == '__main__':
    main()
