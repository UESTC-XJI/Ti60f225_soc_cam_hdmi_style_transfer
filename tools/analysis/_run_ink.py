"""Ink-wash style training driver for Ti60F225.

Runs the four stages in order, with the ink-specific loss configuration and the
STYLE_ORACLE_DIR fix for the firmware self-test trap.

Usage (PowerShell):
  .venv/Scripts/python.exe tools/analysis/_run_ink.py --stage teacher
  .venv/Scripts/python.exe tools/analysis/_run_ink.py --stage student
  .venv/Scripts/python.exe tools/analysis/_run_ink.py --stage export
  .venv/Scripts/python.exe tools/analysis/_run_ink.py --stage firmware
  .venv/Scripts/python.exe tools/analysis/_run_ink.py --stage all

Add --dataset mono to use the ink-dominant (pure 水墨) subset instead.
Add --dry-run to print commands without executing.
"""
import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PY = ROOT / '.venv' / 'Scripts' / 'python.exe'
TRAIN = ROOT / 'tools' / 'analysis' / '_train_v2.py'

# Ink-wash loss configuration.
#   tone     -> controls ink density / paper brightness (CRITICAL: Gram is blind
#               to global tone because VGG features are mean/std normalised)
#   quantile -> matches the luminance distribution
#   cast     -> warm paper base (xuan paper R-B ~ +35)
#   sky/grain/stroke OFF -> those are ukiyo-e / monet signatures, not ink
INK_LOSS = [
    '--content-weight', '0.7',
    '--style-weight', '1500',
    '--distill-weight', '30.0',
    '--tv-weight', '0.0',
    '--tone-weight', '300.0',
    # ABSOLUTE contrast target.  Measured on 160 ink paintings (trainer units):
    #   ink std 0.1176 (30.0 LSB) vs photo std 0.1835 (46.8 LSB)
    # The previous RELATIVE target (photo_std * 0.86) was 56% too high, and
    # contrast is the STRONGEST domain discriminator (Welch t = -11.5) - so this
    # single parameter was the main cause of the "faded photograph" result.
    '--contrast-absolute', '0.1176',
    '--quantile-weight', '0.3',
    '--cast-weight', '1.0',
    # ink R-B = +0.1398 in [0,1] (35.6 LSB).  The old 0.0294/-0.0361 cast gave
    # only +0.0655 (16.7 LSB), i.e. 47% of the target.  Keep the three components
    # summing to 0 so brightness is untouched.
    '--cast-rgb', '0.0699,0.0000,-0.0699',
    '--sky-weight', '0.0',
    '--grain-weight', '0.0',
    '--stroke-weight', '0.0',
    '--stroke-coarse-weight', '0.0',
    '--identity-weight', '10.0',
]


def run(cmd, dry):
    printable = ' '.join(str(c) for c in cmd)
    print('\n>>> ' + printable, flush=True)
    if dry:
        return 0
    env = dict(os.environ)
    r = subprocess.run([str(c) for c in cmd], env=env)
    if r.returncode != 0:
        print('!! command failed with code %d' % r.returncode, flush=True)
        sys.exit(r.returncode)
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--stage', required=True,
                    choices=['teacher', 'student', 'export', 'firmware', 'all'])
    ap.add_argument('--dataset', default='museum', choices=['museum', 'mono'])
    ap.add_argument('--size', type=int, default=512)
    ap.add_argument('--steps-teacher', type=int, default=2500)
    ap.add_argument('--steps-student', type=int, default=8000)
    ap.add_argument('--qat-after', type=int, default=5500)
    ap.add_argument('--batch-teacher', type=int, default=6)
    ap.add_argument('--batch-student', type=int, default=12)
    ap.add_argument('--dry-run', action='store_true')
    a = ap.parse_args()

    data_dir = ROOT / '_data' / ('ink_%s' % a.dataset)
    manifest = ROOT / 'reports' / 'ink' / ('data_%s' % a.dataset) / 'manifest.json'
    teacher = ROOT / 'reports' / 'ink' / 'teacher' / ('step_%06d.pt' % a.steps_teacher)
    student = ROOT / 'reports' / 'ink' / 'student' / ('step_%06d.pt' % a.steps_student)
    export = ROOT / 'reports' / 'ink' / 'export'

    # preflight
    print('=' * 72)
    print('INK TRAINING  dataset=%s  size=%d' % (a.dataset, a.size))
    print('=' * 72)
    for p, label in [(PY, 'venv python'), (TRAIN, 'train script'),
                     (manifest, 'manifest'), (data_dir, 'dataset dir')]:
        print('  %-14s %-58s %s' % (label, str(p).replace(str(ROOT) + '\\', ''), 'OK' if p.exists() else 'MISSING'))
    if not manifest.exists() or not data_dir.exists():
        print('\n!! dataset/manifest missing -- run prepare.py first')
        sys.exit(1)

    # GUARD: style_quantiles() sorts N*size*size elements per channel and
    # torch.quantile caps at 2**24. Exceeding it crashes at startup, not at
    # training time -- so fail fast here with an actionable message.
    refs_path = manifest.parent / 'style_refs.json'
    if refs_path.exists():
        n_refs = len(json.loads(refs_path.read_text()))
        cap = (2 ** 24) // (a.size * a.size)
        quantile_on = any(x.startswith('--quantile-weight') for x in INK_LOSS) and \
            INK_LOSS[INK_LOSS.index('--quantile-weight') + 1] not in ('0', '0.0')
        print('  %-14s %-58s %d refs (quantile cap %d)'
              % ('style_refs', str(refs_path).replace(str(ROOT) + '\\', ''), n_refs, cap))
        if quantile_on and n_refs > cap:
            print('\n!! %d style refs exceeds the torch.quantile limit of %d at size=%d.'
                  % (n_refs, cap, a.size))
            print('   style_quantiles() would raise "input tensor is too large" at startup.')
            print('   Fix: reduce refs to <= %d, or set --quantile-weight 0, or use --size 256 (cap 256).'
                  % cap)
            sys.exit(1)

    if a.stage in ('teacher', 'all'):
        run([PY, TRAIN, '--manifest', manifest, '--out', ROOT / 'reports/ink/teacher',
             '--kind', 'teacher', '--steps', a.steps_teacher, '--batch', a.batch_teacher,
             '--size', a.size, '--validate-every', '250'] + INK_LOSS, a.dry_run)

    if a.stage in ('student', 'all'):
        if not teacher.exists() and not a.dry_run:
            print('\n!! teacher checkpoint not found: %s' % teacher)
            sys.exit(1)
        run([PY, TRAIN, '--manifest', manifest, '--out', ROOT / 'reports/ink/student',
             '--kind', 'student', '--teacher', teacher,
             '--steps', a.steps_student, '--batch', a.batch_student,
             '--qat-after', a.qat_after, '--size', a.size,
             '--validate-every', '500'] + INK_LOSS, a.dry_run)

    if a.stage in ('export', 'all'):
        run([PY, ROOT / 'ml/style_transfer/calibrate.py',
             '--checkpoint', student, '--manifest', manifest,
             '--out', ROOT / 'reports/ink/calib'], a.dry_run)
        run([PY, ROOT / 'ml/style_transfer/export.py',
             '--checkpoint', student, '--out', export], a.dry_run)

    if a.stage in ('firmware', 'all'):
        run([PY, ROOT / 'ml/style_transfer/program.py',
             '--model', export, '--out', ROOT / 'rtl/style/model'], a.dry_run)
        # CRITICAL: without this the self-test fixture comes from reports/ukiyoe/export
        os.environ['STYLE_ORACLE_DIR'] = str(export)
        print('\n[env] STYLE_ORACLE_DIR = %s' % export)
        run([PY, ROOT / 'tools/prepare_style_firmware.py'], a.dry_run)

    print('\nDONE (stage=%s)' % a.stage)


if __name__ == '__main__':
    main()
