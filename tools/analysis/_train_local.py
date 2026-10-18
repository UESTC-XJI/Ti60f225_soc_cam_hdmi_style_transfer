"""Run ml/style_transfer/train.py with single-process data loading.

Why: this sandbox blocks named-pipe creation, so PyTorch's multi-process
DataLoader (num_workers>0) fails with PermissionError on WinError 5.
train.py hardcodes num_workers=4 / pin_memory / persistent_workers at line 97.

This wrapper patches the DataLoader defaults and then calls train.main()
unchanged, so no tracked file is modified.  It is only needed in a confined
environment; on a normal host run train.py directly.
"""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent # repo root (moved to tools/analysis)
sys.path.insert(0, str(ROOT / 'ml' / 'style_transfer'))

import torch.utils.data  # noqa: E402

_orig = torch.utils.data.DataLoader


def _patched(*args, **kwargs):
    kwargs['num_workers'] = 0
    kwargs['pin_memory'] = False
    kwargs['persistent_workers'] = False
    return _orig(*args, **kwargs)


torch.utils.data.DataLoader = _patched

import train  # noqa: E402

if __name__ == '__main__':
    train.main()
