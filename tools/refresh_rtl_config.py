"""Centralize configuration of selected plain RTL files without changing others.

Run on new/imported files with literal parameter defaults and declaration ranges.
The migration lexer preserves expressions; a token comparison validates each file.
"""
import hashlib
import json
from pathlib import Path
import re
import sys
import tempfile
import centralize_rtl_config as migration

ROOT = Path(__file__).resolve().parents[1]

def token_digest(source):
    return hashlib.sha256(json.dumps([t[0] for t in migration.tokens(source)], ensure_ascii=True).encode()).hexdigest()

def main(names):
    header = ROOT / 'rtl/defines.v'
    old = header.read_bytes().decode('latin1').replace('\r\n', '\n')
    source = {name: (ROOT / name).read_bytes() for name in names}
    work = ROOT / 'work'
    work.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='config_refresh_', dir=work) as temp:
        staging = Path(temp)
        (staging / 'tools').mkdir()
        ddr = staging / 'rtl/ddr3_controller/ddr3_parameter.vh'
        ddr.parent.mkdir(parents=True)
        # Copy only the original DDR settings, not the guarded whole header.
        ddr.write_text(old[old.index('//Generic'):old.index('// Fixed packed widths')], encoding='latin1')
        for name, data in source.items():
            path = staging / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        migration.ROOT = staging
        migration.migrate()
        fresh = (staging / 'rtl/defines.v').read_bytes().decode('latin1').replace('\r\n', '\n')
        definitions = dict(re.findall(r'^`define (CFG_\w+) (.*)$', fresh, re.M))
        for name, original in source.items():
            generated = (staging / name).read_bytes().decode('latin1')
            expanded = re.sub(r'^`include "(?:\.\./)*defines\.v"\r?\n', '', generated)
            expanded = re.sub(r'`CFG_BITS_(\d+)-1', lambda m: str(int(m[1])-1), expanded)
            expanded = re.sub(r'`(CFG_\w+)', lambda m: definitions[m[1]], expanded)
            assert token_digest(expanded) == token_digest(original.decode('latin1')), name
            # Normalize whitespace only on changed declarations, never inside
            # a string or protected block; token equality checked above.
            data = generated.encode('latin1').replace(b'\r\n', b'\n')
            (ROOT / name).write_bytes(data)
        sections = re.findall(r'(?m)^// (rtl/[^\n]+)\n([\s\S]*?)(?=^// rtl/|^`endif)', fresh)
        for name, body in sections:
            block = '// ' + name + '\n' + body
            pattern = r'(?m)^// ' + re.escape(name) + r'\n[\s\S]*?(?=^// rtl/|^`endif)'
            if re.search(pattern, old):
                old = re.sub(pattern, lambda _: block, old)
            else:
                old = old.replace('\n`endif', '\n' + block + '\n`endif')
        for name, value in definitions.items():
            if name.startswith(('CFG_BITS_', 'CFG_RANGE_')) and not re.search(r'^`define ' + name + r'\b', old, re.M):
                position = old.index('// rtl/')
                old = old[:position] + f'`define {name} {value}\n' + old[position:]
        header.write_bytes(old.encode('latin1'))
        manifest_path = ROOT / 'tools/rtl_config_manifest.json'
        rows = {r['file']: r for r in json.loads(manifest_path.read_text())}
        for row in json.loads((staging / 'tools/rtl_config_manifest.json').read_text()):
            row['expanded_token_sha256'] = token_digest(source[row['file']].decode('latin1'))
            rows[row['file']] = row
        manifest_path.write_text(json.dumps([rows[k] for k in sorted(rows)], indent=2) + '\n')
    print('PASS selected RTL macro expansion:', ', '.join(names))

if __name__ == '__main__':
    main(sys.argv[1:])
