"""Read-only image/domain/split audit for the proposed style-transfer dataset."""
from pathlib import Path
from collections import Counter, defaultdict
import argparse
import csv
import hashlib
import json
from PIL import Image, ImageDraw, ImageOps


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--dataset', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    with (args.dataset / 'metadata.csv').open(encoding='utf-8-sig', newline='') as handle:
        metadata = list(csv.DictReader(handle))
    manifest = {row['image_path']: row for row in metadata}
    sizes, modes, counts = defaultdict(Counter), defaultdict(Counter), Counter()
    domains = Counter((row['domain'], row['split']) for row in metadata)
    hashes, pixel_hashes = defaultdict(list), defaultdict(list)
    missing, corrupt, unlisted, inconsistent = [], [], [], []
    image_paths = {}
    for folder in ['trainA', 'trainB', 'testA', 'testB']:
        image_paths[folder] = sorted((args.dataset / folder).glob('*.jpg'))
        for path in image_paths[folder]:
            relative = path.relative_to(args.dataset).as_posix()
            counts[folder] += 1
            if relative not in manifest:
                unlisted.append(relative)
            hashes[hashlib.sha256(path.read_bytes()).hexdigest()].append(relative)
            try:
                with Image.open(path) as im:
                    im.load()
                    sizes[folder][f'{im.width}x{im.height}'] += 1
                    modes[folder][im.mode] += 1
                    rgb = im.convert('RGB')
                    digest = hashlib.sha256(f'{im.size}'.encode() + rgb.tobytes()).hexdigest()
                    pixel_hashes[digest].append(relative)
            except Exception as exc:
                corrupt.append({'path': relative, 'error': str(exc)})
        print(f'AUDIT {folder}: {counts[folder]} images', flush=True)
    for relative in manifest:
        if not (args.dataset / relative).is_file():
            missing.append(relative)
        folder = relative.split('/')[0]
        expected_split = 'train' if folder.startswith('train') else 'test'
        expected_domain = folder[-1]
        row = manifest[relative]
        if row['split'] != expected_split or not row['domain'].startswith(expected_domain + ' '):
            inconsistent.append({'path': relative, 'split': row['split'], 'domain': row['domain']})

    def duplicates(groups, cross_split=False):
        return [paths for paths in groups.values() if len(paths) > 1 and
                (not cross_split or len({path.split('/')[0][:4] for path in paths}) > 1)]

    result = {'dataset': str(args.dataset.resolve()), 'metadata_rows': len(metadata),
              'metadata_unique_paths': len(manifest), 'folder_counts': dict(counts),
              'metadata_domains': [{'domain': domain, 'split': split, 'count': count}
                                   for (domain, split), count in sorted(domains.items())],
              'resolutions': {folder: dict(counter) for folder, counter in sizes.items()},
              'modes': {folder: dict(counter) for folder, counter in modes.items()},
              'missing': missing, 'corrupt': corrupt, 'unlisted': unlisted,
              'metadata_folder_disagreements': inconsistent,
              'duplicate_byte_groups': duplicates(hashes),
              'duplicate_pixel_groups': duplicates(pixel_hashes),
              'train_test_byte_overlap': duplicates(hashes, True),
              'train_test_pixel_overlap': duplicates(pixel_hashes, True),
              'pairing': 'not established: matching filenames are not evidence of paired targets',
              'artist_verification': 'metadata is a label, not independently authenticated artwork provenance',
              'near_duplicate_check': 'not executed: perceptual/scene-level split remains to be reviewed'}
    (args.output / 'dataset_audit.json').write_text(json.dumps(result, ensure_ascii=False, indent=2)
                                                  + '\n', encoding='utf-8')
    sheet = Image.new('RGB', (960, 4 * 194), '#eeeeee')
    draw = ImageDraw.Draw(sheet)
    for row, (folder, paths) in enumerate(image_paths.items()):
        draw.text((8, row * 194 + 4), f'{folder} ({len(paths)})', fill='black')
        for col in range(min(6, len(paths))):
            path = paths[col * (len(paths) - 1) // 5] if len(paths) > 1 else paths[0]
            with Image.open(path) as im:
                thumb = ImageOps.contain(im.convert('RGB'), (152, 152))
            sheet.paste(thumb, (col * 160 + 4, row * 194 + 24))
            draw.text((col * 160 + 4, row * 194 + 179), path.name, fill='black')
    sheet.save(args.output / 'dataset_contact_sheet.png')
    print(json.dumps({'folder_counts': dict(counts), 'resolutions': result['resolutions'],
                      **{key: len(result[key]) for key in ['missing', 'unlisted', 'corrupt',
                         'metadata_folder_disagreements', 'duplicate_pixel_groups',
                         'train_test_byte_overlap', 'train_test_pixel_overlap']}}, ensure_ascii=False), flush=True)


if __name__ == '__main__':
    main()
