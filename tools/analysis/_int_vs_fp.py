"""Integer vs float comparison for the deployed Monet style network.

Runs the committed integer oracle (NumPy only) against the FP32/QAT checkpoints.
The FP/QAT paths need torch; if torch is unavailable we still run the integer
side plus a reference-implementation cross-check, and report clearly what was
and was not executed.
"""
import json
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent.parent # repo root (moved to tools/analysis)
ART = ROOT / 'ml' / 'style_transfer' / 'artifacts'
INT = ART / 'integer'
sys.path.insert(0, str(ROOT / 'ml' / 'style_transfer'))

from integer import IntegerNetwork  # noqa: E402

print('=' * 74)
print('Integer vs Float comparison - deployed Monet network')
print('=' * 74)
print()

# ---------------------------------------------------------------- integer side
graph = json.loads((INT / 'graph.json').read_text(encoding='utf-8'))
print('graph.json:')
for k in ('format_version', 'rounding', 'input', 'output', 'padding',
          'activation', 'accumulator', 'affine', 'payload_bytes',
          'maximum_affine_abs_bound', 'qat_checkpoint'):
    if k in graph:
        print('  %-26s %s' % (k, graph[k]))
print('  %-26s %d' % ('layers', len(graph['layers'])))
print()

params = np.load(INT / 'parameters.npz')
print('parameters.npz arrays:', len(params.files))
print()

# ------------------------------------------------------- deterministic fixtures
# The firmware embeds a 32x24 integer self-test; reproduce its input generator
# exactly (tools/prepare_style_firmware.py) so the comparison is grounded.
i = np.arange(32 * 24, dtype=np.uint32).reshape(24, 32)
rgb = np.stack([(i * 13 + 7) & 255, (i * 7 + 29) & 255, (i * 3 + 97) & 255],
               axis=2).astype(np.uint8)
print('fixture: 32x24 synthetic RGB (matches firmware self-test generator)')
print('  input  min/max/mean = %d / %d / %.1f'
      % (rgb.min(), rgb.max(), rgb.mean()))
print()

net = IntegerNetwork(INT)
out = net(rgb)
print('integer output:')
print('  shape %s dtype %s' % (out.shape, out.dtype))
print('  min/max/mean = %d / %d / %.1f' % (out.min(), out.max(), out.mean()))
print()

# ------------------------------------------------- cross-check against firmware
selftest = ROOT / 'software' / 'firmware' / 'style_selftest.h'
if selftest.exists():
    txt = selftest.read_text(encoding='utf-8', errors='replace')
    import re
    def grab(name):
        m = re.search(r'style_test_%s\[768\]\s*=\s*\{(.*?)\};' % name, txt, re.S)
        if not m:
            return None
        vals = [int(v, 16) for v in re.findall(r'0x([0-9a-fA-F]{8})u', m.group(1))]
        return np.array(vals, dtype=np.uint32).reshape(24, 32)

    exp_words = grab('expected')
    if exp_words is not None:
        exp = np.stack([(exp_words & 255),
                        (exp_words >> 8) & 255,
                        (exp_words >> 16) & 255], axis=2).astype(np.uint8)
        diff = np.abs(out.astype(np.int16) - exp.astype(np.int16))
        mse = float((diff.astype(np.float64) ** 2).mean())
        psnr = -10 * np.log10(max(mse, 1e-12))
        print('cross-check vs firmware embedded expectation:')
        print('  max abs diff = %d LSB' % diff.max())
        print('  MAE          = %.4f LSB' % diff.mean())
        print('  MSE          = %.6f' % mse)
        print('  PSNR         = %.2f dB' % psnr)
        print('  identical    = %s' % bool((diff == 0).all()))
        print()
    else:
        print('firmware expectation array not parsed')
        print()
else:
    print('style_selftest.h not found; skipping firmware cross-check')
    print()

# ------------------------------------------------------------- layer-by-layer
print('layer-by-layer trace (first pass, 32x24):')
net(rgb, trace=True)
print('  %-4s %-10s %-5s %-5s %-5s  %-9s %-9s' %
      ('idx', 'name', 'k', 's', 'up', 'acc min', 'acc max'))
for t in net.last_trace[:8]:
    L = t['layer']
    print('  %-4d %-10s %-5d %-5d %-5d  %-9d %-9d'
          % (L['index'], L['name'], L['kernel'], L['stride'], L['upsample'],
             int(t['acc'].min()), int(t['acc'].max())))
print('  ... (%d layers total)' % len(net.last_trace))
print()

# ----------------------------------------------------------- float side (torch)
print('-' * 74)
print('float side (requires torch):')
try:
    import torch
    print('  torch', torch.__version__, 'cuda', torch.cuda.is_available())
    HAVE_TORCH = True
except Exception as e:
    print('  torch NOT available (%s: %s)' % (type(e).__name__, e))
    HAVE_TORCH = False

if HAVE_TORCH:
    from model import Student
    import torch.nn.functional as F

    def load(p):
        ck = torch.load(p, map_location='cpu', weights_only=False)
        m = Student()
        m.load_state_dict(ck['model'])
        m.eval()
        if ck.get('config', {}).get('activation_scales'):
            m.set_scales(ck['config']['activation_scales'])
        return m, ck

    x = torch.from_numpy(rgb.astype(np.float32) / 255).permute(2, 0, 1)[None]

    fp, _ = load(ART / 'student_fp.pt')
    qat, qck = load(ART / 'student_qat.pt')
    # Match evaluate.py: the QAT checkpoint is run with fake-quant active.
    qat.set_qat(True)

    with torch.no_grad():
        yfp = fp(x)
        yqat = qat(x)

    def to_u8(t):
        return (t[0].permute(1, 2, 0).numpy() * 255).round().clip(0, 255).astype(np.uint8)

    fp_u8 = to_u8(yfp)
    qat_u8 = to_u8(yqat)

    # Compare in the same float [0,1] space evaluate.py uses.
    yit_f = torch.from_numpy(out.astype(np.float32) / 255).permute(2, 0, 1)[None]

    def report(name, a, b):
        """PSNR over [0,1] range => MAX=1.0 (matches evaluate.py)."""
        mse = float(F.mse_loss(a, b).item())
        mae_lsb = float((a - b).abs().mean().item() * 255)
        print('  %-22s MAE=%6.3f LSB   MSE=%.8f   PSNR=%6.2f dB'
              % (name, mae_lsb, mse, -10 * np.log10(max(mse, 1e-12))))

    print()
    print('  (float [0,1] space, same convention as ml/style_transfer/evaluate.py)')
    report('integer vs QAT', yit_f, yqat)
    report('integer vs FP', yit_f, yfp)
    report('QAT vs FP', yqat, yfp)

    # VGG-based style metrics need torchvision; run them only if available.
    try:
        from torchvision.models import vgg16, VGG16_Weights

        class Features(torch.nn.Module):
            def __init__(self):
                super().__init__()
                self.net = vgg16(weights=VGG16_Weights.IMAGENET1K_V1).features[:23].eval()
                self.net.requires_grad_(False)
                self.register_buffer('mean', torch.tensor([.485, .456, .406])[None, :, None, None])
                self.register_buffer('std', torch.tensor([.229, .224, .225])[None, :, None, None])

            def forward(self, z):
                z = (z - self.mean) / self.std
                o = []
                for i, m in enumerate(self.net):
                    z = m(z)
                    if i in (3, 8, 15, 22):
                        o.append(z)
                return o

        refs = json.loads((ROOT / 'reports/style_demo/data_v2/style_refs.json').read_text())
        ds = json.loads((ROOT / 'reports/style_demo/data_v2/manifest.json').read_text())['dataset']
        root = Path(ds)
        if root.exists():
            feats = Features()
            with torch.no_grad():
                target = [g.mean(0, keepdim=True)
                          for g in [gram_(f) for f in feats(
                              torch.stack([load_img(root / n) for n in refs]))]]

            def gram_(z):
                n, c, h, w = z.shape
                f = z.flatten(2).float()
                return (f @ f.transpose(1, 2)) / (c * h * w)

            print()
            print('  style Gram MSE vs the 8 reference paintings:')
            for nm, arr in (('integer', out), ('QAT', qat_u8), ('FP', fp_u8)):
                t = torch.from_numpy(arr.astype(np.float32) / 255).permute(2, 0, 1)[None]
                with torch.no_grad():
                    f = feats(t)
                    s = sum(F.mse_loss(gram_(a), b).item() for a, b in zip(f, target))
                print('    %-8s %.8f' % (nm, s))
        else:
            print()
            print('  style Gram MSE skipped: dataset not present at %s' % root)
    except ImportError:
        print()
        print('  style Gram MSE skipped: torchvision not installed')
    except Exception as e:
        print()
        print('  style Gram MSE skipped: %s: %s' % (type(e).__name__, str(e)[:60]))
else:
    print()
    print('  Skipping float comparison - torch not installed yet.')
    print('  The integer oracle above ran fully; it is the authoritative')
    print('  reference for what the FPGA computes.')

print()
print('=' * 74)
print('DONE')
print('=' * 74)
