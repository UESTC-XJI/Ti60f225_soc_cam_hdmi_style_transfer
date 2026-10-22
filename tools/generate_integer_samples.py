"""Generate reproducible held-out INT8 image pairs and a local HTML gallery."""
import argparse, hashlib, html, json, sys, time, zipfile
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'ml/style_transfer'))
from integer import IntegerNetwork


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--count', type=int, default=100)
    parser.add_argument('--size', type=int, default=256)
    parser.add_argument('--out', type=Path, default=ROOT / 'reports/style_demo/samples_100')
    args = parser.parse_args()
    assert args.count > 0 and args.size > 0 and args.size % 4 == 0
    manifest_path = ROOT / 'reports/style_demo/data_v2/manifest.json'
    data = json.loads(manifest_path.read_text())
    evaluation = json.loads((ROOT / 'docs/style_demo_results/metrics.json').read_text())
    assert sha(manifest_path) == evaluation['manifest_sha256']
    records = data['records']
    old_paths = {item['path'] for item in evaluation['items']}
    old_groups = {r['group'] for r in records if r['path'] in old_paths}
    representatives = {}
    for record in sorted(records, key=lambda r: r['path']):
        if record['domain'] == 'B' and record['split'] == 'test' and record['group'] not in old_groups:
            representatives.setdefault(record['group'], record)
    candidates = sorted(representatives.values(), key=lambda r: r['path'])
    assert len(candidates) >= args.count, len(candidates)
    indices = np.linspace(0, len(candidates) - 1, args.count, dtype=int)
    selected = [candidates[i] for i in indices]
    assert len({r['group'] for r in selected}) == args.count
    model_path = ROOT / 'ml/style_transfer/artifacts/integer'
    model_info = json.loads((model_path.parent / 'manifest.json').read_text())
    for name in ['graph.json', 'parameters.npz', 'model.bin']:
        assert sha(model_path / name) == model_info['files']['integer/' + name]['sha256']
    network = IntegerNetwork(model_path)
    out = args.out
    assert not (out / 'manifest.json').exists(), 'Choose a fresh output directory to preserve earlier samples.'
    for folder in ['input', 'output', 'pairs', 'pages']:
        (out / folder).mkdir(parents=True, exist_ok=True)
    rows = []
    overview = Image.new('RGB', (1920, ((args.count + 9) // 10) * 116), 'white')
    overview_draw = ImageDraw.Draw(overview)
    pages = []
    begin = time.monotonic()
    for index, record in enumerate(selected, 1):
        source = Path(data['dataset']) / record['path']
        assert sha(source) == record['sha256'], 'Dataset image changed: ' + record['path']
        with Image.open(source) as original:
            original = original.convert('RGB').resize((args.size, args.size), Image.Resampling.BICUBIC)
        rgb = np.asarray(original).copy()
        result = network(rgb)
        assert result.shape == rgb.shape and result.dtype == np.uint8
        output = Image.fromarray(result)
        name = f'{index:03d}.png'
        original.save(out / 'input' / name)
        output.save(out / 'output' / name)
        pair = Image.new('RGB', (args.size * 2, args.size + 24), 'white')
        pair.paste(original, (0, 24)); pair.paste(output, (args.size, 24))
        draw = ImageDraw.Draw(pair)
        draw.text((4, 5), f'{index:03d} Input', fill='black')
        draw.text((args.size + 4, 5), 'INT8 output', fill='black')
        pair.save(out / 'pairs' / name)
        page_index = (index - 1) // 10
        if page_index == len(pages):
            pages.append(Image.new('RGB', (args.size * 4, (args.size + 24) * 5), 'white'))
        slot = (index - 1) % 10
        pages[page_index].paste(pair, ((slot % 2) * args.size * 2, (slot // 2) * (args.size + 24)))
        x, y = ((index - 1) % 10) * 192, ((index - 1) // 10) * 116
        overview.paste(original.resize((96, 96), Image.Resampling.LANCZOS), (x, y + 20))
        overview.paste(output.resize((96, 96), Image.Resampling.LANCZOS), (x + 96, y + 20))
        overview_draw.text((x + 3, y + 3), f'{index:03d} Input / INT8', fill='black')
        rows.append({'index': index, 'source': record['path'], 'group': record['group'],
                     'source_sha256': record['sha256'], 'input': 'input/' + name,
                     'output': 'output/' + name, 'pair': 'pairs/' + name,
                     'pixel_mae_from_input_lsb': float(np.abs(result.astype(np.int16) - rgb.astype(np.int16)).mean())})
        if index % 10 == 0:
            print(f'SAMPLES {index}/{args.count} elapsed={time.monotonic() - begin:.1f}s', flush=True)
    for index, page in enumerate(pages, 1):
        page.save(out / 'pages' / f'{index:02d}.png')
    overview.save(out / 'overview.png')
    cards = ''.join(f'<figure><a href="{r["pair"]}"><img loading="lazy" src="{r["pair"]}" alt="样例 {r["index"]}"></a><figcaption>{r["index"]:03d} · {html.escape(r["source"])}</figcaption></figure>' for r in rows)
    gallery = f'''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>100 个 INT8 风格转换样例</title>
<style>body{{margin:24px;background:#f4f4f4;font:16px system-ui;color:#222}}main{{display:grid;grid-template-columns:repeat(auto-fit,minmax(360px,1fr));gap:18px}}figure{{margin:0;background:white;padding:12px;border-radius:8px}}img{{width:100%;height:auto}}figcaption{{margin-top:8px;overflow-wrap:anywhere}}a{{color:inherit}}</style>
<h1>{args.count} 个 INT8 风格转换样例</h1><p>每组左侧为原图，右侧为整数模型输出；点击可查看原尺寸。全部来自保留测试集，且与此前 64 张评估照片的近似图分组不同。</p>
<p>使用当前莫奈单风格模型，{args.size}×{args.size} 输入，离线整数推理。<a href="overview.png">查看全部总览</a></p><main>{cards}</main></html>'''
    (out / 'index.html').write_text(gallery, encoding='utf-8')
    images = list((out / 'input').glob('*.png')) + list((out / 'output').glob('*.png')) + list((out / 'pairs').glob('*.png'))
    assert len(images) == args.count * 3
    for path in images:
        with Image.open(path) as im:
            im.verify()
    files = {p.relative_to(out).as_posix(): {'bytes': p.stat().st_size, 'sha256': sha(p)} for p in out.rglob('*') if p.is_file()}
    report = {'count': args.count, 'width': args.size, 'height': args.size, 'split': 'reserved B test',
              'selection': 'one representative per near-duplicate group, exclude all groups of previous 64 test evaluation images; deterministic spread over sorted remaining paths',
              'manifest_sha256': sha(manifest_path), 'model_sha256': sha(model_path / 'model.bin'),
              'parameters_sha256': sha(model_path / 'parameters.npz'), 'samples': rows, 'files': files,
              'wall_seconds': time.monotonic() - begin, 'scope': 'Offline integer model output, not FPGA HDMI captures or an additional perceptual quality assessment.'}
    (out / 'manifest.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    archive = out / 'samples_100.zip'
    with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=1) as bundle:
        for path in sorted(out.rglob('*')):
            if path.is_file() and path != archive:
                bundle.write(path, path.relative_to(out).as_posix())
    (out / 'archive_sha256.txt').write_text(sha(archive) + '  ' + archive.name + '\n', encoding='ascii')
    print(f'PASS {args.count} distinct INT8 samples, verified 300 PNGs; gallery={out / "index.html"}', flush=True)


if __name__ == '__main__':
    main()
