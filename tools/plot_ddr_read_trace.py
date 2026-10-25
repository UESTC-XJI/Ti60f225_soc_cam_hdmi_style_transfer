"""Render reports/ddr_read_trace/*/read_channel.trace into one interactive HTML page.

Reads the traces written by tools/trace_ddr_read.py, computes per-variant
occupancy statistics for the CNN job window, and embeds a compact copy of
each trace (gzip + base64) so the page can zoom down to single cycles.
The page needs a browser with DecompressionStream (Chromium 80+, Firefox 113+).

Usage: python tools/plot_ddr_read_trace.py [--out reports/ddr_read_trace/read_channel.html]
"""
from pathlib import Path
from collections import Counter
import argparse, base64, bisect, gzip, json, re

ROOT = Path(__file__).resolve().parents[1]
TRACE_DIR = ROOT / 'reports/ddr_read_trace'
VARIANTS = [
    ('baseline', '无 beat 缓冲，固定显示优先'),
    ('buffer', '有 beat 缓冲，固定显示优先'),
    ('adaptive', '有 beat 缓冲，按需仲裁 + urgent 预留（当前 main）'),
]
# Category order must match CATS in the page script.
CATS = ['c_beat', 'c_wait', 'd_beat', 'd_wait', 'd_bp', 'blocked', 'idle']
HISTORY = [
    ('docs/style_ddr_optimization_results/simulation/baseline/metrics.json', 'baseline（旧 RTL）'),
    ('docs/style_ddr_optimization_results/simulation/buffer/metrics.json', 'buffer（旧 RTL）'),
    ('docs/style_ddr_optimization_results/simulation/adaptive/metrics.json', 'adaptive controls4（旧 RTL）'),
    ('reports/style_demo/ddr_optimization/adaptive_merged/metrics.json', 'adaptive merged'),
    ('docs/style_ddr_optimization_results/simulation/adaptive_vga480/metrics.json', 'adaptive 640×480（旧 RTL）'),
]


def category(code):
    phase, owner = code & 7, code >> 3 & 1
    if phase == 0:
        return 5 if (code >> 4 & 1) and (code >> 6 & 1) else 6
    if phase in (1, 2):
        return 3 if owner else 1
    if phase == 3:
        return 2 if owner else 0
    return 4  # RREADY low; only the display side ever holds it


def varint(out, value):
    while value >= 128:
        out.append(value & 127 | 128)
        value >>= 7
    out.append(value)


def load(name):
    changes, levels, layers, bursts = [], [], [], []
    for line in (TRACE_DIR / name / 'read_channel.trace').open():
        f = line.split()
        if f[0] == 'C':
            changes.append((int(f[1]), int(f[2])))
        elif f[0] == 'L':
            levels.append(int(f[2]))
        elif f[0] == 'N':
            layers.append((int(f[1]), int(f[2])))
        elif f[0] == 'A':
            bursts.append((int(f[1]), int(f[2]), int(f[3])))
    # Job window = first rising to first falling edge of network busy (bit 9).
    start = end = None
    previous = 0
    for cycle, code in changes:
        busy = code >> 9 & 1
        if busy and not previous and start is None:
            start = cycle
        if previous and not busy and start is not None:
            end = cycle
            break
        previous = busy
    if start is None:
        raise SystemExit(f'{name}: CNN job never started in trace')
    if end is None:
        end = changes[-1][0] + 1
    return changes, levels, layers, bursts, start, end


def summarize(name, label):
    changes, levels, layers, bursts, start, end = load(name)
    total = end - start
    share = Counter()
    blocked_runs, blocked_levels = [], Counter()
    for (cycle, code), (following, _) in zip(changes, changes[1:] + [(end, 0)]):
        a, b = max(cycle, start), min(following, end)
        if b <= a:
            continue
        cat = category(code)
        share[CATS[cat]] += b - a
        if cat == 5:
            blocked_runs.append(b - a)
            for x in range(a, b, 32):
                level = levels[min(x // 32, len(levels) - 1)]
                blocked_levels['≥448' if level >= 448 else '<448'] += min(32, b - x)
    job_layers = [(c - start, n) for c, n in layers if start <= c < end and (n or c == start)]
    log = (TRACE_DIR / name / 'simulation.log').read_text(errors='replace')
    passed = bool(re.search(r'^PASS ', log, re.M))
    fatal = re.search(r'^FATAL: .*?:\d+: (.*)$', log, re.M)
    packed = bytearray()
    previous = 0
    for cycle, code in changes:
        varint(packed, cycle - previous)
        previous = cycle
        packed += (code & 0x3ff).to_bytes(2, 'little')
    level_bytes = b''.join(min(v, 65535).to_bytes(2, 'little') for v in levels)
    runs = sorted(blocked_runs)
    return {
        'name': name, 'label': label, 'start': start, 'end': end, 'total': total,
        'cnn_cycles': round(total * 1.485),
        'share': {k: share.get(k, 0) for k in CATS},
        'bursts': {'cnn': sum(1 for c, o, _ in bursts if start <= c < end and o == 0),
                   'display': sum(1 for c, o, _ in bursts if start <= c < end and o == 1)},
        'blocked': {'cycles': sum(runs), 'runs': len(runs), 'max': runs[-1] if runs else 0,
                    'median': runs[len(runs) // 2] if runs else 0,
                    'near_full': blocked_levels['≥448']},
        'layers': job_layers,
        'passed': passed, 'fatal': fatal[1] if fatal else '',
        'changes': base64.b64encode(gzip.compress(bytes(packed), 9)).decode(),
        'levels': base64.b64encode(gzip.compress(level_bytes, 9)).decode(),
    }


def history():
    rows = []
    for path, label in HISTORY:
        p = ROOT / path
        if not p.exists():
            continue
        d = json.loads(p.read_text())
        c = d['counters_100mhz']
        rows.append({'label': label, 'height': d['height'], 'cycles': d['cycles'], 'ms': d['milliseconds'],
                     'ticks': c['ticks'], 'ar': c['cnn_ar_wait'], 'gap': c['cnn_return_gap'],
                     'dbp': c['display_r_backpressure'], 'rb': c['cnn_read_beats'], 'drb': c['display_read_beats']})
    return rows


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--out', default=str(TRACE_DIR / 'read_channel.html'))
    args = p.parse_args()
    data = [summarize(n, l) for n, l in VARIANTS if (TRACE_DIR / n / 'read_channel.trace').exists()]
    if not data:
        raise SystemExit('no traces found; run tools/trace_ddr_read.py first')
    template = (Path(__file__).with_name('ddr_read_trace_template.html')).read_text(encoding='utf-8')
    payload = json.dumps({'variants': data, 'history': history()}, ensure_ascii=False, separators=(',', ':'))
    Path(args.out).write_text(template.replace('/*__DATA__*/null', payload), encoding='utf-8')
    print(f'wrote {args.out} ({Path(args.out).stat().st_size >> 10} KiB)')
    for v in data:
        s = v['share']
        print(f"{v['name']:9s} job {v['total']:8d} cycles  " +
              '  '.join(f"{k} {100 * s[k] / v['total']:.1f}%" for k in CATS))


if __name__ == '__main__':
    main()
