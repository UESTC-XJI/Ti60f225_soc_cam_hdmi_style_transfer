"""Build the NEW ink dataset meeting the three requirements.

Requirements:
  R1 paper background NOT prominent  -> background must read neutral, not beige
  R2 mostly black/white + pale       -> low saturation, high pastel share
  R3 strong stylisation              -> a large, measurable gap from the photo
                                        domain, so the demo effect is obvious

Pipeline:
  1. gather candidate images: newly downloaded sumi-e + the strict-pass subset
     from the local museum/mono sets
  2. score each with the REFINED features (background-region R-B, pastel share,
     ink coverage, contrast)
  3. keep those meeting C1+C2, then rank by C3 (gap from the photo domain)
  4. dedupe by perceptual hash (near-duplicates would leak across splits)
  5. write train/val/test with a hashed, reproducible split
  6. emit manifest.json in the same schema the trainer expects, plus
     style_refs.json (stratified by the same features)

Nothing here needs the GPU.
"""
import hashlib
import json
import pathlib
import random
import sys

import numpy as np
from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
DATA = ROOT / '_data'
UK = ROOT / 'reports' / 'ink'
# Names fixed by the user: dataset folder 黑白ink, version v1.
# The model outputs are reports/ink/teacher_黑白v1 and student_黑白v1.
OUTNAME = '黑白ink'
OUT = DATA / OUTNAME
REPORT = UK / ('data_' + OUTNAME)
REPORT.mkdir(parents=True, exist_ok=True)
SIZE = 384


def load(p):
    return np.asarray(Image.open(p).convert('RGB').resize(
        (SIZE, SIZE), Image.Resampling.BICUBIC))


def feats(a):
    f = a.astype(np.float32)
    L = f @ np.array([.299, .587, .114]) / 255.0
    light = L > 0.60
    dark = L < 0.35
    mx = f.max(2)
    sat = (mx - f.min(2)) / np.maximum(mx, 1)
    bg_rb = (float((f[:, :, 0][light] - f[:, :, 2][light]).mean() / 255.0)
             if light.sum() > 10 else float('nan'))
    return dict(
        bg_rb=bg_rb,
        ink_rb=(float((f[:, :, 0][dark] - f[:, :, 2][dark]).mean() / 255.0)
                if dark.sum() > 10 else float('nan')),
        bg_frac=float(light.mean()), ink_frac=float(dark.mean()),
        sat=float(sat.mean()), pastel=float((sat < 0.15).mean()),
        std=float(L.std()),
        contrast=float(np.percentile(L, 95) - np.percentile(L, 5)),
        lum=float(L.mean()),
        warm=float((f[:, :, 0] > f[:, :, 2]).mean()),
    )


def dhash(a, s=16):
    g = np.asarray(Image.fromarray(a.astype(np.uint8)).convert('L').resize(
        (s + 1, s), Image.Resampling.BILINEAR)).astype(np.int16)
    return (g[:, 1:] > g[:, :-1]).flatten().astype(np.uint8)


# ------------------------------------------------------------------ candidates
cands = []
sumi = DATA / 'ink_sumi' / 'raw'
if sumi.exists():
    f = sorted(sumi.glob('*'))
    cands += [(p, 'sumi') for p in f if p.is_file()]
    print('sumi-e downloaded        : %d' % len(f))

for tag, mfile in (('museum', 'data_museum'), ('mono', 'data_mono')):
    mp = UK / mfile / 'manifest.json'
    if not mp.exists():
        continue
    man = json.loads(mp.read_text())
    ds = pathlib.Path(man['dataset'])
    A = [r['path'] for r in man['records'] if r['domain'] == 'A']
    cands += [(ds / p, tag) for p in A]
    print('local %-18s : %d' % (tag, len(A)))

print('total candidates         : %d' % len(cands))

# ------------------------------------------------------------------- scoring
print()
print('scoring (this takes a while on CPU)...')
rows = []
for i, (p, tag) in enumerate(cands):
    try:
        a = load(p)
    except Exception:
        continue
    f = feats(a)
    if np.isnan(f['bg_rb']):
        continue
    f['path'] = str(p)
    f['tag'] = tag
    f['h'] = dhash(a).tobytes()
    rows.append(f)
    if (i + 1) % 400 == 0:
        print('  scored %d/%d' % (i + 1, len(cands)), flush=True)
print('  usable feature rows: %d' % len(rows))

# --------------------------------------------------- criteria + stylisation
# photo reference for the stylisation gap: use the existing B domain stats
ph_mp = UK / 'data_museum' / 'manifest.json'
ph = json.loads(ph_mp.read_text())
ph_ds = pathlib.Path(ph['dataset'])
Bv = [r['path'] for r in ph['records']
      if r['domain'] == 'B' and r['split'] == 'validation'][:64]
prows = [feats(load(ph_ds / p)) for p in Bv]
P_sat = float(np.mean([r['sat'] for r in prows]))
P_rb = float(np.mean([r['bg_rb'] for r in prows]))
P_lum = float(np.mean([r['lum'] for r in prows]))
print()
print('photo reference: sat %.3f  bg_rb %+.3f  lum %.3f' % (P_sat, P_rb, P_lum))

# C1 (neutral background), C2 (b/w + pale), C3 (stylisation gap)
for r in rows:
    r['gap_sat'] = P_sat - r['sat']
    r['gap_lum'] = r['lum'] - P_lum
    r['style_score'] = r['gap_sat'] + 0.5 * abs(r['gap_lum'])

C1 = lambda r: r['bg_rb'] < 0.04
C2 = lambda r: r['sat'] < 0.18 and r['pastel'] > 0.40
C3 = lambda r: r['style_score'] > 0.20

for label, fn in (('C1 neutral bg', C1), ('C2 b/w+pale', C2),
                  ('C1+C2', lambda r: C1(r) and C2(r)),
                  ('C1+C2+C3 (strict)', lambda r: C1(r) and C2(r) and C3(r))):
    k = sum(1 for r in rows if fn(r))
    print('  %-20s %5d / %d  (%.1f%%)' % (label, k, len(rows), 100 * k / len(rows)))

keep = [r for r in rows if C1(r) and C2(r)]
print()
print('  kept (C1+C2): %d' % len(keep))
by_tag = {}
for r in keep:
    by_tag[r['tag']] = by_tag.get(r['tag'], 0) + 1
print('  by source: %s' % by_tag)

# ------------------------------------------------------------------ dedupe
groups = {}
for r in keep:
    groups.setdefault(r['h'], []).append(r)
uniq = [g[0] for g in groups.values()]
dups = sum(len(g) - 1 for g in groups.values())
print('  after dedupe: %d unique (removed %d near-duplicates)' % (len(uniq), dups))

# ------------------------------------------------------- split + write out
# rank by stylisation strength so the strongest images also appear in test
uniq.sort(key=lambda r: -r['style_score'])
print()
print('  style_score: min %.3f  median %.3f  max %.3f'
      % (uniq[-1]['style_score'], uniq[len(uniq) // 2]['style_score'],
         uniq[0]['style_score']))

for split in ('trainA', 'testA', 'trainB', 'testB', 'valB'):
    (OUT / split).mkdir(parents=True, exist_ok=True)
# BUG FIX: the first build omitted a validation split entirely.  _train_v2.py
# requires B/validation and computes val[i*(len-1)//7] for i in range(8), so an
# empty list raised "IndexError: list index out of range" at startup.  The photo
# domain now carries train/validation/test, split 70/15/15, because the trainer
# draws its 8 validation images from B/validation.

records = []
for i, r in enumerate(uniq):
    src = pathlib.Path(r['path'])
    # 80/20 split, deterministic from the content hash
    h = hashlib.sha256(r['h'] + b'neutral-v1').digest()
    split = 'test' if (h[0] % 10) < 2 else 'train'
    sub = 'testA' if split == 'test' else 'trainA'
    dst = OUT / sub / ('ink_%05d.jpg' % i)
    try:
        im = Image.open(src).convert('RGB')
        im.thumbnail((1024, 1024), Image.Resampling.LANCZOS)
        im.save(dst, 'JPEG', quality=92)
    except Exception as e:
        print('  write fail %s: %r' % (src.name, e))
        continue
    b = dst.read_bytes()
    records.append(dict(
        path='%s/%s' % (sub, dst.name), domain='A', split=split,
        sha256=hashlib.sha256(b).hexdigest(),
        rgb_sha256=hashlib.sha256(
            np.asarray(Image.open(dst).convert('RGB').resize(
                (64, 64), Image.Resampling.BILINEAR)).tobytes()).hexdigest(),
        dhash=r['h'].hex(), group='N_%d' % i, original_split='web',
        tag=r['tag']))

# copy the photo domain so content is identical across styles.
# B needs train + validation + test, because _train_v2.py reads its 8 validation
# images from B/validation.  The source B/validation is small, so:
#   train      = source B/train up to 2000
#   validation = source B/validation (the trainer subsamples 8 from it)
#   test       = source B/test up to 400
import shutil
by_split = {}
for split, sub in (('train', 'trainB'), ('validation', 'valB'), ('test', 'testB')):
    cap = 2000 if split == 'train' else (400 if split == 'test' else 600)
    ps = [r['path'] for r in ph['records']
          if r['domain'] == 'B' and r['split'] == split][:cap]
    by_split[split] = 0
    for p in ps:
        s = ph_ds / p
        if not s.exists():
            continue
        d = OUT / sub / pathlib.Path(p).name
        if not d.exists():
            shutil.copy2(s, d)
        by_split[split] += 1
        records.append(dict(
            path='%s/%s' % (sub, d.name), domain='B', split=split,
            sha256='', rgb_sha256='', dhash='', group='B_%s_%d' % (split, by_split[split]),
            original_split=split, tag='reused'))
print('  B copied: %s' % by_split)

man_out = dict(
    dataset=str(OUT), method='web sumi-e + local strict-pass ink, C1+C2 filtered, '
    'dhash dedupe, hashed split; B carries train/validation/test',
    seed=20261018, records=records)
(REPORT / 'manifest.json').write_text(json.dumps(man_out, ensure_ascii=False, indent=1))

nRecA = sum(1 for r in records if r['domain'] == 'A')
print()
print('=' * 84)
print('WROTE  %s' % OUT)
print('=' * 84)
print('  A images  train %d  test %d'
      % (sum(1 for r in records if r['domain'] == 'A' and r['split'] == 'train'),
         sum(1 for r in records if r['domain'] == 'A' and r['split'] == 'test')))
print('  B images  train %d  test %d'
      % (sum(1 for r in records if r['domain'] == 'B' and r['split'] == 'train'),
         sum(1 for r in records if r['domain'] == 'B' and r['split'] == 'test')))
print('  manifest  %s  (%d records)' % (REPORT / 'manifest.json', len(records)))

# ------------------------------------------------------------- style refs
random.seed(20261018)
trainA = [r for r in records if r['domain'] == 'A' and r['split'] == 'train']
by_feat = sorted([r for r in uniq if any(
    x['path'].endswith(pathlib.Path(r['path']).name) for x in trainA)],
    key=lambda r: r['sat'])
refs = []
if by_feat:
    step = max(len(by_feat) // 32, 1)
    refs = [pathlib.Path(r['path']).name for r in by_feat[::step]][:32]
# BUG FIX: refs must carry the trainA/ prefix. _train_v2.py resolves them as
# root / name, so a bare filename produced
#   FileNotFoundError: _data/黑白ink/ink_00118.jpg
# The working museum set stores them as 'trainA/ink_00296.jpg'.
refs = ['trainA/' + n for n in refs]
(REPORT / 'style_refs.json').write_text(json.dumps(refs, indent=1))
print('  style_refs %d (stratified by saturation, trainA/ prefix)' % len(refs))
print()
print('NEXT: validate with tools/analysis/_newset_validate.py')
