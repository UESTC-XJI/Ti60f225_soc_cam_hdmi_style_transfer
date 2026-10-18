"""Emit fixed graph microprogram and firmware banked coefficient image.

Compared with the original allocator this version supports a full-resolution
colour head prepended to the graph.

The original hardcoded the four feature bases and the 23-entry (src, dst, skip)
triple list, which only worked for one topology.  This version keeps that exact
body plan (so head-less graphs emit byte-identical output) and inserts the head
into the free DDR region above the body's measured peak.

Bodies verified safe:
  body peak     0x063C2000   (dec.0 writes 1.8432 MB at big)
  head bank A   0x06400000   + 2.4576 MB = 0x06658000
  head bank B   0x06700000   + 2.4576 MB = 0x06958000   < 0x07000000  OK
"""
import argparse
import json
import pathlib

F0, F1, F2, BIG = 0x06000000, 0x060A0000, 0x06120000, 0x06200000
HEAD_A, HEAD_B = 0x06400000, 0x06700000


def body_pairs(n_body):
    """The original four-bank plan, for exactly `n_body` layers (expects 23)."""
    pairs = [(0, F0, 0), (F0, F2, 0), (F2, F1, 0)]
    current = F1
    for _ in range(4):
        other = F2 if current == F1 else F1
        pairs.extend([(current, F0, 0), (F0, other, 0), (other, F0, 0),
                      (F0, other, current)])
        current = other
    pairs.extend([(current, BIG, 0), (BIG, F0, 0), (F0, F1, 0), (F1, 0, 0)])
    if len(pairs) != n_body:
        raise ValueError('the fixed body plan covers %d layers but the graph has '
                         '%d; only the 23-layer body is supported'
                         % (len(pairs), n_body))
    return pairs


def head_pairs(n_head):
    """Ping-pong plan for `n_head` full-resolution layers."""
    if n_head == 0:
        return []
    out = []
    cur, other = HEAD_A, HEAD_B
    for i in range(n_head):
        src = 0 if i == 0 else cur
        out.append((src, other, 0))
        cur, other = other, cur
    return out


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--model', type=pathlib.Path, required=True)
    p.add_argument('--out', type=pathlib.Path, required=True)
    a = p.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)
    g = json.loads((a.model / 'graph.json').read_text())
    layers = g['layers']

    n_head = 0
    for l in layers:
        if l['name'].startswith('head.'):
            n_head += 1
        else:
            break
    n_body = len(layers) - n_head
    if n_body != 23:
        raise ValueError('body must be 23 layers, got %d' % n_body)

    hp = head_pairs(n_head)
    bp = body_pairs(n_body)
    if n_head:
        # enc.0 must now read the head's last output instead of the source frame
        last_bank = hp[-1][1]
        first_body = list(bp[0])
        first_body[0] = last_bank
        bp = [tuple(first_body)] + bp[1:]
    pairs = hp + bp
    assert len(pairs) == len(layers)

    inlevels = [0, 1, 2] + [2] * 16 + [2, 1, 1, 0]
    outlevels = [1, 2, 2] + [2] * 16 + [1, 1, 0, 0]
    # the head runs at full resolution, stride 1
    inlevels = [0] * n_head + inlevels
    outlevels = [0] * n_head + outlevels
    assert len(inlevels) == len(layers)

    words = []
    ledger = []
    for i, (l, (src, dst, skip), il, ol) in enumerate(
            zip(layers, pairs, inlevels, outlevels)):
        # The 6-bit flags field and every downstream offset MUST stay exactly as
        # the RTL decodes them (style_network.sv:20-27):
        #   [4:0] ci [9:5] co [10] kernel3 [11] dw [12] stride2 [13] up2
        #   [14] residual [15] relu [17:16] il [19:18] ol
        #   [27:20] weight_base [35:28] norm_base
        #   [67:36] src [99:68] dst [131:100] skip
        # Bits 132..159 are unused, so the new is_last flag goes at bit 132
        # WITHOUT shifting anything.
        flags = int(l['kernel'] == 3) | (int(l['dw']) << 1) \
            | (int(l['stride'] == 2) << 2) | (int(l['upsample'] == 2) << 3) \
            | (int(l['residual'] >= 0) << 4) | (int(l['relu']) << 5)
        word = 0
        offset = 0
        for value, bits in [(l['ci'], 5), (l['co'], 5), (flags, 6), (il, 2), (ol, 2),
                            (l['weight_base'], 8), (l['norm_base'], 8),
                            (src, 32), (dst, 32), (skip, 32)]:
            word |= value << offset
            offset += bits
        assert offset == 132, 'descriptor layout drifted to %d bits' % offset
        if i == len(layers) - 1:
            word |= 1 << 132          # is_last, in previously unused bits
        words.append(f'{word:040x}\n')
        ledger.append(dict(layer=l['name'], src=hex(src), dst=hex(dst),
                           skip=hex(skip), inlevel=il, outlevel=ol,
                           is_last=bool(i == len(layers) - 1)))
    (a.out / 'program.hex').write_text(''.join(words))
    (a.out / 'program.json').write_text(json.dumps(ledger, indent=2))

    verilog = ('// Generated graph descriptor ROM; literal cases preserve '
               'synthesis initialization.\n'
               'function [159:0] descriptor_word;\n  input [4:0] index;\n'
               '  begin case(index)\n')
    verilog += ''.join(f"    5'd{i}:descriptor_word=160'h{word.strip()};\n"
                       for i, word in enumerate(words))
    verilog += "    default:descriptor_word=0;\n  endcase end\nendfunction\n"
    (a.out / 'program.vh').write_text(verilog)

    for name in ('coeff.hex', 'coeff.bin', 'model.bin', 'graph.json'):
        (a.out / name).write_bytes((a.model / name).read_bytes())
    blob = (a.model / 'coeff.bin').read_bytes()
    ints = [int.from_bytes(blob[i:i + 4], 'little') for i in range(0, len(blob), 4)]
    header = ('/* Generated from the trained INT8 model; 24 words per coefficient '
              'row. */\n#include <stdint.h>\n'
              'static const uint32_t style_coefficients[6144] = {\n')
    header += ''.join('  ' + ','.join(f'0x{v:08x}u' for v in ints[i:i + 8]) + ',\n'
                      for i in range(0, len(ints), 8)) + '};\n'
    (a.out / 'style_weights.h').write_text(header)


if __name__ == '__main__':
    main()
