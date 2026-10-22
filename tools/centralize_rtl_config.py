"""One-shot, lossless RTL configuration migration, with a preprocessing audit.

Comments/strings are tokenized, balanced expressions are preserved verbatim,
and parameter names/interfaces remain unchanged. Not an HDL elaborator.
"""
from pathlib import Path
import json
import re

ROOT = Path(__file__).resolve().parents[1]
TOKEN = re.compile(r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|\\[^\s]+|[A-Za-z_$][\w$]*|\d+|\S')

def tokens(source):
    return [(m.group(), m.start(), m.end()) for m in TOKEN.finditer(source)
            if not m.group().startswith(('//', '/*'))]

def matching(ts, start):
    pairs = {'(': ')', '[': ']', '{': '}'}
    stack = []
    for j in range(start, len(ts)):
        v = ts[j][0]
        if v in pairs:
            stack.append(pairs[v])
        elif v in pairs.values():
            if not stack or stack.pop() != v:
                raise ValueError(('unbalanced', ts[j]))
            if not stack:
                return j
    raise ValueError(('unterminated', ts[start]))

def split(ts, start, end):
    i = first = start
    while i < end:
        if ts[i][0] in ('(', '[', '{'):
            i = matching(ts, i) + 1
        elif ts[i][0] == ',':
            yield first, i
            first = i = i + 1
        else:
            i += 1
    if first < end:
        yield first, end

def migrate():
    header = ROOT / 'rtl/defines.v'
    if header.exists():
        raise SystemExit('Already migrated; edit defines.v directly.')
    definitions = []
    manifest = []
    widths = set()
    fixed_ranges = set()
    ddr = ROOT / 'rtl/ddr3_controller/ddr3_parameter.vh'
    original_ddr = ddr.read_bytes().decode('latin1')
    paths = sorted(p for p in (ROOT / 'rtl').rglob('*')
                   if p.suffix in ('.v', '.sv', '.vh', '.svh')
                   and p != ddr)
    for path in paths:
        source = path.read_bytes().decode('latin1')
        # Several DDR files contain an editable shell plus encrypted bodies.
        # Mask protected blocks for parsing, preserving every original byte.
        visible = re.sub(r'`pragma protect begin_protected[\s\S]*?`pragma protect end_protected',
                         lambda m: ' ' * len(m.group()), source)
        ts = tokens(visible)
        prefix = 'CFG_' + re.sub(r'\W', '_', str(path.relative_to(ROOT / 'rtl')).upper())
        edits = []
        defs = []
        used = set()

        def add(start, end, label):
            if start >= end or any(start < b and end > a for a, b, _ in edits):
                return
            value = source[start:end]
            # Preserve comments at their original location. Use tokens for the
            # macro expression, preventing line comments from swallowing it.
            expr = ' '.join(t[0] for t in tokens(value))
            # Token joining must preserve sized literals and macro/function
            # tokens; stripping comments from the original is safer instead.
            expr = re.sub(r'//[^\n]*|/\*[\s\S]*?\*/', ' ', value)
            expr = ' '.join(expr.split())
            name = prefix + '_' + label
            base = name
            k = 2
            while name in used:
                name = base + '_' + str(k)
                k += 1
            used.add(name)
            defs.append((name, expr))
            edits.append((start, end, '`' + name))

        # Defaults and localparams, including comma-separated declarations.
        i = 0
        while i < len(ts):
            if ts[i][0] not in ('parameter', 'localparam'):
                i += 1
                continue
            kind = ts[i][0].upper()
            j = i + 1
            while j < len(ts):
                if ts[j][0] in ('(', '[', '{'):
                    j = matching(ts, j) + 1
                elif ts[j][0] in (';', ')'):
                    break
                else:
                    j += 1
            for a, b in split(ts, i + 1, j):
                eq = next((k for k in range(a, b) if ts[k][0] == '='), None)
                if eq is not None and eq + 1 < b:
                    add(ts[eq + 1][1], ts[b - 1][2], kind + '_' + ts[eq - 1][0].upper())
            i = j + 1

        # Only #(...) followed by an instance identifier and port list;
        # module parameter lists and procedural delays are excluded.
        for i in range(len(ts) - 2):
            if ts[i][0] != '#' or ts[i + 1][0] != '(':
                continue
            end = matching(ts, i + 1)
            if end + 2 >= len(ts) or not re.fullmatch(r'[A-Za-z_$][\w$]*', ts[end + 1][0]):
                continue
            after = end + 2
            if ts[after][0] == '[':
                after = matching(ts, after) + 1
            if ts[after][0] != '(':
                continue
            instance = ts[end + 1][0].upper()
            for index, (a, b) in enumerate(split(ts, i + 2, end)):
                if ts[a][0] == '.':
                    close = matching(ts, a + 2)
                    if close > a + 3:
                        add(ts[a + 3][1], ts[close - 1][2], 'INST_' + instance + '_' + ts[a + 1][0].upper())
                else:
                    add(ts[a][1], ts[b - 1][2], 'INST_' + instance + '_ARG_' + str(index))

        # Declaration widths/dimensions only; leave procedural bit selects
        # and protocol fields unchanged. Derived ranges still refer to the
        # instance's own parameters after expansion.
        declaration = False
        range_number = 0
        i = 0
        while i < len(ts):
            value = ts[i][0]
            if value in ('wire', 'reg', 'logic', 'bit', 'input', 'output', 'inout',
                         'function', 'parameter', 'localparam'):
                declaration = True
            elif value in (';', '=', ')', 'begin', 'end'):
                declaration = False
            if value == '[' and declaration:
                end = matching(ts, i)
                a, b = ts[i + 1][1], ts[end - 1][2]
                expr = source[a:b]
                if ':' in expr and not any(a < y and b > x for x, y, _ in edits):
                    fixed = re.fullmatch(r'\s*(\d+)\s*:\s*(\d+)\s*', expr)
                    if fixed:
                        high, low = map(int, fixed.groups())
                        if low == 0:
                            width = high + 1
                            widths.add(width)
                            replacement = f'`CFG_BITS_{width}-1:0'
                        else:
                            fixed_ranges.add((high, low))
                            replacement = f'`CFG_RANGE_{high}_{low}'
                        edits.append((a, b, replacement))
                    else:
                        range_number += 1
                        add(a, b, 'RANGE_' + str(range_number))
                i = end
            i += 1
        for a, b, replacement in sorted(edits, reverse=True):
            source = source[:a] + replacement + source[b:]
        source = '`include "' + '../' * (len(path.relative_to(ROOT / 'rtl').parts) - 1) + 'defines.v"\n' + source
        path.write_bytes(source.encode('latin1'))
        definitions.append('// ' + path.relative_to(ROOT).as_posix() + '\n' +
                           ''.join(f'`define {name} {value}\n' for name, value in defs))
        manifest.append({'file': path.relative_to(ROOT).as_posix(), 'config_expressions': len(defs),
                         'fixed_ranges': len(edits) - len(defs)})
    header.write_text('// Central editable RTL configuration. See RTL_CONFIG_README.md.\n'
                      '`ifndef SOC_CAM_HDMI_DEFINES_V\n`define SOC_CAM_HDMI_DEFINES_V\n\n'
                      '// DDR geometry, AXI buses and timing (original names retained).\n' + original_ddr.replace('\r\n', '\n') + '\n'
                      '// Fixed packed widths; protocol slices retain their original meaning.\n' +
                      ''.join(f'`define CFG_BITS_{w} {w}\n' for w in sorted(widths)) + '\n' +
                      ''.join(f'`define CFG_RANGE_{a}_{b} {a}:{b}\n' for a, b in sorted(fixed_ranges)) + '\n' +
                      '\n'.join(definitions) + '\n`endif\n', encoding='latin1')
    ddr.write_text('// Compatibility include; edit DDR settings in rtl/defines.v.\n`include "../defines.v"\n', encoding='ascii')
    (ROOT / 'tools/rtl_config_manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'Migrated {len(manifest)} files, {sum(x["config_expressions"] for x in manifest)} expressions, '
          f'{sum(x["fixed_ranges"] for x in manifest)} fixed ranges.')

if __name__ == '__main__':
    migrate()
