"""Generate the PWA icon set (four style tiles on a dark rounded square).

    python tools/ble_web/gen_icons.py [output-dir]

Writes icon-192.png, icon-512.png, icon-maskable-512.png, apple-touch-icon.png,
favicon-32.png and favicon.svg. Requires Pillow and numpy (build-time only).
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

# Four style swatches, matching --starry/--candy/--mosaic/--feathers in app.css.
TILES = [
    ((0x4F, 0x6B, 0xFF), (0x8B, 0x5C, 0xF6)),   # starry
    ((0xFF, 0x5F, 0xA2), (0xFF, 0x9F, 0x43)),   # candy
    ((0x0F, 0xD1, 0xB8), (0x3B, 0xD1, 0x6F)),   # mosaic
    ((0xFF, 0xC2, 0x45), (0xFF, 0x8C, 0x42)),   # feathers
]


def vertical_gradient(size, top, bottom):
    y = np.linspace(0.0, 1.0, size, dtype=np.float32)[:, None, None]
    y = np.broadcast_to(y, (size, size, 1))
    top = np.array(top, dtype=np.float32)[None, None, :]
    bottom = np.array(bottom, dtype=np.float32)[None, None, :]
    return Image.fromarray((top + (bottom - top) * y).astype(np.uint8), 'RGB')


def background(size):
    """Dark navy gradient with a soft blue glow behind the tiles."""
    img = np.asarray(vertical_gradient(size, (0x1A, 0x23, 0x3D), (0x07, 0x0A, 0x12))).astype(np.float32)
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32)
    cx = cy = (size - 1) / 2.0
    d = np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2) / (size * 0.62)
    glow = np.clip(1.0 - d, 0.0, 1.0) ** 2
    img += glow[:, :, None] * np.array([0x1D, 0x2C, 0x5C], dtype=np.float32) * 0.9
    return Image.fromarray(np.clip(img, 0, 255).astype(np.uint8), 'RGB')


def rounded_mask(size, radius):
    mask = Image.new('L', (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size - 1, size - 1), radius=radius, fill=255)
    return mask


def glossy_tile(size, top, bottom, radius):
    tile = vertical_gradient(size, top, bottom).convert('RGBA')
    # Slight top-left highlight so the tiles read as physical swatches.
    glow = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse((-size * 0.35, -size * 0.55, size * 0.95, size * 0.45),
                                 fill=(255, 255, 255, 46))
    tile = Image.alpha_composite(tile, glow)
    tile.putalpha(rounded_mask(size, radius))
    return tile


def make_icon(size, content=0.64, corner=0.22, opaque=False):
    """Render at 4x and downsample for clean edges."""
    s = size * 4
    bg = background(s).convert('RGBA')
    gap = int(s * 0.038)
    tile = int((s * content - gap) / 2)
    radius = int(tile * 0.24)
    origin = (s - tile * 2 - gap) // 2
    positions = [(origin, origin), (origin + tile + gap, origin),
                 (origin, origin + tile + gap), (origin + tile + gap, origin + tile + gap)]
    for (x, y), (top, bottom) in zip(positions, TILES):
        swatch = glossy_tile(tile, top, bottom, radius)
        bg.alpha_composite(swatch, (x, y))
    if not opaque:
        bg.putalpha(rounded_mask(s, int(s * corner)))
    return bg.resize((size, size), Image.LANCZOS)


FAVICON_SVG = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <defs>
    <linearGradient id="a" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#4f6bff"/><stop offset="1" stop-color="#8b5cf6"/></linearGradient>
    <linearGradient id="b" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#ff5fa2"/><stop offset="1" stop-color="#ff9f43"/></linearGradient>
    <linearGradient id="c" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#0fd1b8"/><stop offset="1" stop-color="#3bd16f"/></linearGradient>
    <linearGradient id="d" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#ffc245"/><stop offset="1" stop-color="#ff8c42"/></linearGradient>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#1a233d"/><stop offset="1" stop-color="#070a12"/></linearGradient>
  </defs>
  <rect width="64" height="64" rx="14" fill="url(#bg)"/>
  <rect x="11" y="11" width="19" height="19" rx="5" fill="url(#a)"/>
  <rect x="34" y="11" width="19" height="19" rx="5" fill="url(#b)"/>
  <rect x="11" y="34" width="19" height="19" rx="5" fill="url(#c)"/>
  <rect x="34" y="34" width="19" height="19" rx="5" fill="url(#d)"/>
</svg>
"""


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).parent / 'icons')
    out.mkdir(parents=True, exist_ok=True)
    make_icon(192).save(out / 'icon-192.png')
    make_icon(512).save(out / 'icon-512.png')
    make_icon(512, content=0.56, corner=0.0, opaque=True).save(out / 'icon-maskable-512.png')
    make_icon(180, opaque=True).convert('RGB').save(out / 'apple-touch-icon.png')
    make_icon(32).save(out / 'favicon-32.png')
    (out / 'favicon.svg').write_text(FAVICON_SVG, encoding='utf-8')
    for p in sorted(out.iterdir()):
        print(f'{p.name:26s} {p.stat().st_size:6d} B')


if __name__ == '__main__':
    main()
