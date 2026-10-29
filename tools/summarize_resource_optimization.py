"""Summarize saved final implementation reports and hash the reviewed inputs."""
from pathlib import Path
import hashlib
import json
import re
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'reports/resource_optimization'
NS = {'e': 'http://www.efinixinc.com/enf_proj'}


def read(path):
    return path.read_text(encoding='utf-8-sig')


def project_signature(path):
    def node(element):
        attrs = dict(element.attrib)
        if element.tag.endswith('param') and attrs.get('name') == 'work_dir':
            attrs['value'] = '<isolated build directory>'
        return [element.tag, sorted(attrs.items()), (element.text or '').strip(),
                [node(child) for child in element]]
    return node(ET.parse(path).getroot())


def build_summary(label):
    directory = OUT / (label + '_build')
    log = read(OUT / (label + '_compile.log'))
    for stage in ['map', 'interface', 'pnr', 'pgm']:
        assert re.search(r'^\s*' + stage + r'\s*:\s*PASS', log, re.M), (label, stage)
    place = read(directory / 'ti60f225_oob.place.rpt')
    resource = {}
    for key, name in [('xlr', 'XLRs'), ('ram', 'Memory Blocks'), ('dsp', 'DSP Blocks')]:
        match = re.search(r'^' + name + r': (\d+) / (\d+) \(([\d.]+)%\)', place, re.M)
        assert match, (label, key)
        resource[key] = {'used': int(match[1]), 'total': int(match[2]),
                         'percent': float(match[3])}
    timing = read(directory / 'ti60f225_oob.timing.rpt')
    assert re.search(r'status\s*:\s*final', timing)
    # Limit parsing to the clock relationship summary, excluding path details.
    table = timing.split('Setup (Max) Clock Relationship', 1)[1].split(
        '---------- Clock Relationship Summary (end)', 1)[0]
    setup, hold = table.split('Hold (Min) Clock Relationship', 1)
    relationships = {}
    for key, section in [('setup', setup), ('hold', hold)]:
        rows = [{'launch': m[1], 'capture': m[2], 'constraint_ns': float(m[3]),
                 'slack_ns': float(m[4]), 'edge': m[5]}
                for m in re.finditer(r'^\s*(\S+)\s+(\S+)\s+(-?[\d.]+)\s+'
                                     r'(-?[\d.]+)\s+(\([RF]-[RF]\))\s*$', section, re.M)]
        assert rows and all(row['slack_ns'] > 0 for row in rows), (label, key)
        relationships[key] = rows
    return {'status': 'PASS', 'resources': resource, 'clock_relationships': relationships,
            'minimum_setup_ns': min(row['slack_ns'] for row in relationships['setup']),
            'minimum_hold_ns': min(row['slack_ns'] for row in relationships['hold'])}


def main():
    assert project_signature(ROOT / 'ti60f225_cam_hdmi.xml') == project_signature(
        OUT / 'build_inputs/resource_optimized.xml'), 'active project differs from compiled project'
    assert project_signature(OUT / 'baseline_inputs/ti60f225_cam_hdmi.xml') == project_signature(
        OUT / 'build_inputs/resource_baseline.xml'), 'baseline project differs from saved input'
    baseline, optimized = build_summary('baseline'), build_summary('optimized')
    netlist = read(OUT / 'optimized_build/ti60f225_oob.map.v')
    mapped = re.findall(r'^\s*(EFX_(?:DP)?RAM10)\s+\\([^\s]+)', netlist, re.M)
    arrays = ['osd_apb/capture_statistics/hist_mem',
              'osd_apb/capture_statistics/previous_row', 'osd_apb/hist_cache',
              'information_overlay/histogram/counts',
              'information_overlay/histogram/heights', 'osd_db/page_mem']
    ram_mapping = {array: [{'primitive': primitive, 'instance': instance}
                          for primitive, instance in mapped if instance.startswith(array)]
                   for array in arrays}
    assert [len(ram_mapping[array]) for array in arrays] == [2, 1, 1, 1, 1, 1], 'target memory failed BRAM inference'
    hierarchy = read(OUT / 'optimized_build/ti60f225_oob.hier_util.rpt')
    assert 'edb_top' not in hierarchy
    assert 'edb_top' in read(OUT / 'baseline_build/ti60f225_oob.hier_util.rpt')
    assert 'system_hardJtag_debug_logic_debugger' in hierarchy, 'CPU JTAG debugger missing'
    assert 'depack40bit_inst' in hierarchy, 'RAW10 unpacker missing'
    assert not re.search(r'depack(?:48|56|64)bit_inst', hierarchy), 'unused unpacker retained'
    tests = {}
    logs = ['capture_bram', 'osd_pixels', 'video_3a', 'video_3a_full', 'rtl_regression',
            'osd_cleanup', 'hdmi_startup', 'frame_diagnostics', 'shared_ddr',
            'resize_checks', 'firmware_runtime', 'camera_3a_runtime',
            'config_audit', 'optimization_audit']
    for name in logs:
        content = read(OUT / (name + '.log'))
        assert 'PASS' in content and not re.search(r'FATAL|Traceback|^FAIL', content, re.M), name
        tests[name] = {'status': 'PASS', 'log': name + '.log',
                       'pass_lines': [line for line in content.splitlines() if line.startswith('PASS')]}
    saved = json.loads(read(OUT / 'optimization_audit.json'))
    assert saved['status'] == 'PASS'
    result = {'date': '2026-10-12', 'tool': 'Efinity 2026.1.132 / Icarus Verilog',
              'status': 'PASS', 'baseline': baseline, 'optimized': optimized,
              'xlr_saved': baseline['resources']['xlr']['used'] - optimized['resources']['xlr']['used'],
              'bram_mapping': ram_mapping, 'tests': tests, 'hardware_validation': 'not executed',
              'csi_protocol_simulation': saved['vendor_csi_protocol_simulation'],
              'timing_scope': 'existing SDC analyzed clock relationships; interface/JTAG warnings retained'}
    (OUT / 'validation.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    project = ET.parse(ROOT / 'ti60f225_cam_hdmi.xml')
    files = {ROOT / item.get('name') for item in project.findall('.//e:design_file', NS)}
    files.update(path for folder in ['rtl', 'soc', 'ip', 'software/firmware']
                 for path in (ROOT / folder).rglob('*') if path.is_file()
                 and path.suffix.lower() in {'.v', '.sv', '.vhd', '.vh', '.mem', '.memh', '.mif', '.hex', '.c', '.h', '.s', '.json'})
    files.update(ROOT / name for name in ['ti60f225_cam_hdmi.xml', 'ti60f225_oob.sdc',
                 'ti60f225_oob.peri.xml', 'debug_profile.wizard.json',
                 'tools/rtl_config_manifest.json', 'docs/RESOURCE_OPTIMIZATION_PLAN.md',
                 'docs/PROJECT_HANDOFF.md', 'docs/INTEGRATION_LOG.md'])
    files.update(ROOT / 'tools' / (name + '.py') for name in [
        'check_rtl_config', 'check_resource_optimization', 'test_resource_optimization',
        'summarize_resource_optimization'])
    files.update(ROOT / 'tests' / name for name in [
        'capture_bram_backpressure_tb.sv', 'osd_bram_pixels_tb.sv', 'video_3a_tb.sv'])
    files.update(path for path in OUT.rglob('*') if path.is_file() and
                 (path.suffix in {'.bit', '.elf', '.log', '.rpt', '.xml'} or path.name == 'validation.json'))
    files.update(path for path in (OUT / 'baseline_inputs').rglob('*') if path.is_file())
    files.update([OUT / 'README.md', OUT / 'optimization_audit.json'])
    hashes = {path.relative_to(ROOT).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
              for path in sorted(files)}
    (OUT / 'manifest.json').write_text(json.dumps({'status': 'PASS', 'sha256': hashes}, indent=2)
                                       + '\n', encoding='utf-8')
    print('PASS final build reports, constrained setup/hold, target BRAM mapping, P2/P3 structure and saved regression logs')
    print(f"XLR {baseline['resources']['xlr']['used']} -> {optimized['resources']['xlr']['used']}; "
          f"setup {optimized['minimum_setup_ns']} ns; hold {optimized['minimum_hold_ns']} ns")


if __name__ == '__main__':
    main()
