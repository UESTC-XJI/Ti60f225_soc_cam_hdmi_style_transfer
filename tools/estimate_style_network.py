"""Arithmetic/traffic estimates, NOT synthesis or measured accelerator FPS."""
from pathlib import Path
import csv
import json
import math

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'reports/style_transfer_planning'


def network(width=640, height=480, channels=24, blocks=4):
    rows = []

    def layer(name, w, h, ci, co, kernel, depthwise=False, bn=True):
        weights = co * kernel * kernel if depthwise else ci * co * kernel * kernel
        reduction = kernel * kernel if depthwise else ci * kernel * kernel
        # 8 output lanes x 12 reduction lanes; depthwise maps 9 taps/lane.
        cycles = w * h * math.ceil(co / 8) * math.ceil(reduction / 12)
        rows.append({'layer': name, 'width': w, 'height': h, 'ci': ci, 'co': co,
                     'kernel': kernel, 'type': 'DW' if depthwise else 'CONV',
                     'weights': weights, 'macs': w * h * weights,
                     'ideal_mac_issue_cycles': cycles, 'bn_channels': co if bn else 0})

    layer('E1 3x3 stride2', width//2, height//2, 3, 8, 3)
    layer('E2 DW3 stride2', width//4, height//4, 8, 8, 3, True)
    layer('E2 PW', width//4, height//4, 8, channels, 1)
    for block in range(blocks):
        for stage in range(2):
            layer(f'R{block+1}.DW{stage+1}', width//4, height//4, channels, channels, 3, True)
            layer(f'R{block+1}.PW{stage+1}', width//4, height//4, channels, channels, 1)
    layer('D1 nearest2 DW3', width//2, height//2, channels, channels, 3, True)
    layer('D1 PW', width//2, height//2, channels, 8, 1)
    layer('D2 nearest2 DW3', width, height, 8, 8, 3, True)
    layer('RGB head PW', width, height, 8, 3, 1, bn=False)
    bn = sum(row['bn_channels'] for row in rows)
    weights = sum(row['weights'] for row in rows)
    return {'width': width, 'height': height, 'bottleneck_channels': channels,
            'residual_blocks': blocks, 'layers': rows,
            'conv_weights': weights, 'bn_channels': bn,
            'trainable_parameters': weights + 2 * bn + 3,
            'macs_per_frame': sum(row['macs'] for row in rows),
            'ideal_mac_issue_cycles': sum(row['ideal_mac_issue_cycles'] for row in rows),
            'quantized_payload_bytes_before_headers': weights + 8 * bn + 3 * 4,
            'payload_note': 'INT8 weights; each BN channel signed M16, shift8, flags8, B32 (8 bytes); head bias32; final requantization/descriptors/padding extra; exporter must prove M/B ranges'}


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    base = network()
    raw = 640 * 480 * 4
    e1 = 320 * 240 * 8
    small = 160 * 120 * 24
    passes = [{'pass': 'E1', 'read_bytes': raw, 'write_bytes': e1},
              {'pass': 'E2 fused DW/PW', 'read_bytes': e1, 'write_bytes': small}]
    passes += [{'pass': f'R{i+1} fused DW/PW/DW/PW+ADD',
                'read_bytes': small, 'write_bytes': small} for i in range(4)]
    passes += [{'pass': 'D1 fused upsample/DW/PW', 'read_bytes': small, 'write_bytes': e1},
               {'pass': 'D2 fused upsample/DW/PW', 'read_bytes': e1, 'write_bytes': raw}]
    cnn_bytes = sum(p['read_bytes'] + p['write_bytes'] for p in passes)
    candidates = {'lite16_r2': network(channels=16, blocks=2), 'balanced24_r4': base,
                  'quality32_r4': network(channels=32, blocks=4),
                  'balanced_720p': network(1280, 720)}
    for value in candidates.values():
        value['ideal_compute_ms_at_148_5_mhz'] = value['ideal_mac_issue_cycles'] / 148_500
        value['note'] = 'issue-cycle estimate excludes DMA stalls, BN fill/drain, residual/upsample bookkeeping and scheduling; not achieved FPS'
    result = {'status': 'PLANNING_ONLY', 'candidates': candidates,
              'balanced_fused_passes': passes, 'cnn_bytes_per_frame': cnn_bytes,
              'at_30fps': {'cnn_MBps': cnn_bytes * 30 / 1e6,
                           'capture_MBps': raw * 30 / 1e6,
                           'two_vga_view_display_60hz_MBps': raw * 2 * 60 / 1e6,
                           'total_MBps': (cnn_bytes * 30 + raw * 30 + raw * 2 * 60) / 1e6},
              'traffic_note': 'compact NHWC INT8 features, fused blocks, RGB in 32-bit words, bars generated without DDR reads; protocol/alignment overhead excluded',
              'resource_budget_not_synthesis': {'additional_mac_dsp': 96,
                  'additional_bn_dsp_budget': 16, 'additional_ram_blocks_max': 80,
                  'additional_xlr_max': 18000},
              'clock_note': 'reuse existing 148.5 MHz capture clock for compute, core 100 MHz for AXI; requires checked CDC/FIFOs'}
    (OUT / 'network_budget.json').write_text(json.dumps(result, indent=2) + '\n')
    with (OUT / 'network_layers.csv').open('w', newline='') as handle:
        writer = csv.DictWriter(handle, fieldnames=list(base['layers'][0]))
        writer.writeheader()
        writer.writerows(base['layers'])
    print(json.dumps({'parameters': base['trainable_parameters'], 'weights': base['conv_weights'],
                      'macs': base['macs_per_frame'], 'ideal_cycles': base['ideal_mac_issue_cycles'],
                      'ideal_ms': candidates['balanced24_r4']['ideal_compute_ms_at_148_5_mhz'],
                      'cnn_bytes': cnn_bytes, 'traffic': result['at_30fps']}, indent=2))


if __name__ == '__main__':
    main()
