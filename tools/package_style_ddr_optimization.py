"""Package the DDR optimization independently of the earlier model release."""
from pathlib import Path
import hashlib
import json
import re
import shutil
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / 'reports/style_demo/ddr_optimization'
FLOW = ROOT / 'outflow_style_ddr_opt'
RESULTS = ROOT / 'docs/style_ddr_optimization_results'
RELEASE = ROOT / 'reports/style_demo/release_ddr_opt'


def digest(path):
    raw = path.read_bytes()
    return {'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}


def copy(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)


def refresh_metrics(folder):
    # Anchor on PASS so read_cycles/compute_cycles cannot be mistaken for total.
    log = (folder / 'simulation.log').read_text()
    total = int(re.search(r'^PASS .*\bcycles=(\d+)', log, re.M)[1])
    metrics = json.loads((folder / 'metrics.json').read_text())
    metrics.update(cycles=total, milliseconds=total / 148500)
    metrics.pop('vga_height_scaling_fps_estimate', None)
    if metrics['height'] == 480:
        metrics['behavioral_ddr_task_fps'] = 148500000 / total
    assert metrics['underflows'] == 0
    assert metrics['capture_beats'] == 76800
    assert metrics['captured_frame_exact_pixels'] == 307200
    (folder / 'metrics.json').write_text(json.dumps(metrics, indent=2) + '\n')
    return metrics


def main():
    runs = {'baseline': 'baseline', 'buffer': 'buffer', 'adaptive_before_control_shrink': 'adaptive',
            'full_before_control_shrink': 'adaptive_vga480',
            'adaptive': 'adaptive_controls4', 'adaptive_vga480': 'adaptive_vga480_controls4'}
    measured = {name: refresh_metrics(REPORT / folder) for name, folder in runs.items()}
    for name in ['adaptive', 'adaptive_vga480']:
        for path, sha in measured[name]['rtl_sha256'].items():
            assert digest(ROOT / path)['sha256'] == sha, 'RTL changed after simulation: ' + path
    for phase in ['map', 'interface', 'pnr', 'pgm']:
        source = REPORT / f'{phase}.log'
        assert re.search(rf'\b{phase}\s*:\s*PASS', source.read_text()), phase
        copy(source, RESULTS / 'efinity' / f'{phase}.log')
    for attempt in ['attempt_timing3', 'attempt_congestion3']:
        for source in (REPORT / attempt).glob('*'):
            copy(source, RESULTS / 'efinity' / attempt / source.name)
    timing = (FLOW / 'ti60f225_oob.timing.rpt').read_text()
    relationship = timing.split('Setup (Max) Clock Relationship')[1].split('NOTE: Values')[0]
    setup, hold = relationship.split('Hold (Min) Clock Relationship')
    pattern = r'^\s*(\S+)\s+(\S+)\s+(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+\([RF]-[RF]\)'
    setup_rows = re.findall(pattern, setup, re.M)
    hold_rows = re.findall(pattern, hold, re.M)
    assert setup_rows and hold_rows
    assert all(float(row[3]) >= 0 for row in setup_rows + hold_rows), 'timing violation'
    setups = {f'{a}->{b}': float(slack) for a, b, _, slack in setup_rows}
    min_hold = min(float(row[3]) for row in hold_rows)
    assert 'No Synchronizer warnings' in (FLOW / 'ti60f225_oob.cdc.rpt').read_text()
    resource_text = (FLOW / 'ti60f225_oob.place.rpt').read_text()
    resources = {}
    for key, label in [('XLR', 'XLRs'), ('RAM', 'Memory Blocks'), ('DSP', 'DSP Blocks')]:
        match = re.search(rf'^{label}: (\d+) / (\d+)', resource_text, re.M)
        assert match, label
        used, capacity = map(int, match.groups())
        assert used <= capacity
        resources[key] = used
        resources[key + '_capacity'] = capacity
    for suffix in ['timing.rpt', 'place.rpt', 'hier_util.rpt', 'cdc.rpt', 'route.rpt', 'res.csv', 'pgm.out']:
        copy(FLOW / f'ti60f225_oob.{suffix}', RESULTS / 'efinity' / f'ti60f225_oob.{suffix}')
    for variant, folder in runs.items():
        for name in ['simulation.log', 'metrics.json']:
            copy(REPORT / folder / name, RESULTS / 'simulation' / variant / name)
    for source in (REPORT / 'units').glob('*.log'):
        assert 'PASS' in source.read_text(), source
        copy(source, RESULTS / 'simulation/units' / source.name)
    for stage in ['network', 'accel', 'errors', 'shared', 'video']:
        for source in (ROOT / 'reports/style_demo' / stage).glob('*.log'):
            assert 'PASS' in source.read_text(), source
            copy(source, RESULTS / 'simulation' / stage / source.name)
    for name in ['ddr_firmware.log', 'firmware_runtime.json']:
        copy(REPORT / name, RESULTS / 'simulation' / name)
    copy(FLOW / 'ti60f225_oob.bit', RELEASE / 'ti60f225_oob.bit')
    copy(ROOT / 'software/firmware/build/soc_video_app.elf', RELEASE / 'soc_video_app.elf')
    copy(ROOT / 'ti60f225_cam_hdmi.xml', RELEASE / 'build_project.xml')

    project = ET.parse(ROOT / 'ti60f225_cam_hdmi.xml')
    sources = {ROOT / p.attrib['name'] for p in project.iter() if p.tag.endswith('design_file')}
    protected = rb'`pragma protect begin_protected[\s\S]*?`pragma protect end_protected'
    original = json.loads((ROOT / 'docs/style_demo_results/baseline_snapshot.json').read_text())
    original_root = Path(original['source'])
    for name, sha in original['overlay_sha256'].items():
        assert digest(original_root / name)['sha256'] == sha, 'original workspace changed: ' + name
    protected_count = 0
    for path in sources:
        blocks = re.findall(protected, path.read_bytes())
        if blocks:
            assert blocks == re.findall(protected, (original_root / path.relative_to(ROOT)).read_bytes()), path
            protected_count += len(blocks)
    assert protected_count
    assert (ROOT / 'rtl/style/model/coeff.bin').read_bytes() == (ROOT / 'ml/style_transfer/artifacts/integer/coeff.bin').read_bytes()
    for directory in ['rtl/style', 'software/firmware', 'tools', 'tests']:
        sources.update(p for p in (ROOT / directory).rglob('*') if p.is_file()
                       and 'build' not in p.parts and '__pycache__' not in p.parts
                       and p.name != 'generate_integer_samples.py'
                       and p.suffix in ['.py', '.sv', '.v', '.vh', '.svh', '.c', '.h', '.S', '.ld', '.hex', '.bin'])
    sources.update(p for p in ROOT.iterdir() if p.suffix in ['.xml', '.sdc'])
    sources.update(ROOT / name for name in ['.gitignore', '.gitattributes', 'docs/DDR_READ_OPTIMIZATION.md',
                                          'docs/STYLE_DEMO_IMPLEMENTATION.md', 'ml/style_transfer/artifacts/manifest.json'])
    resources_line = f"XLR {resources['XLR']}/{resources['XLR_capacity']}，RAM {resources['RAM']}/{resources['RAM_capacity']}，DSP {resources['DSP']}/{resources['DSP_capacity']}"
    full = measured['adaptive_vga480']
    notes = (f'# DDR 优化发布\n\n分支 codex/monet-style-demo，起点 e8ff563。未连接或操作开发板。\n\n'
             f'等待计数、32-beat 显示缓冲、按 FIFO/行期限读优先与 CNN 三次绕过上限。模型/权重未变。\n\n'
             f'640×48 对照：2269633 → 1029441 周期；640×480 并发：{full["cycles"]} 周期，'
             f'{full["milliseconds"]:.3f}ms，{full["behavioral_ddr_task_fps"]:.3f} task fps（DDR 行为模型、单帧密集抓帧、无外层 CPU 竞争）。'
             f'全部 CNN/抓帧像素对拍通过，显示欠载 0；不是板上 FPS。\n\n'
             f'{resources_line}。CNN setup {setups["vid_clk_dvi2->vid_clk_dvi2"]:+.3f}ns，'
             f'100MHz setup {setups["core_clk->core_clk"]:+.3f}ns，最小已报告 hold {min_hold:+.3f}ns。\n\n'
             '新 ti60f225_oob.bit 与 soc_video_app.elf 配套使用。旧 release 不覆盖。'
             '诊断寄存器、UART 字段、仿真范围和后续上板流程见 docs/DDR_READ_OPTIMIZATION.md。\n')
    (RELEASE / 'README.md').write_text(notes, encoding='utf-8')
    for directory in [RESULTS, RELEASE]:
        sources.update(p for p in directory.rglob('*') if p.is_file() and p.name != 'manifest.json')
    manifest = {
        'branch': subprocess.check_output(['git', 'branch', '--show-current'], cwd=ROOT, text=True).strip(),
        'baseline_commit': 'e8ff563',
        'source_parent_commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
        'efinity': '2026.1.132', 'device': 'Ti60F225 I3', 'resources': resources,
        'pnr_settings': {param.attrib['name']: param.attrib['value'] for node in project.iter()
                         if node.tag.endswith('place_and_route') for param in node},
        'setup_slack_ns': setups, 'min_reported_hold_slack_ns': min_hold,
        'simulation': measured, 'protected_blocks_unchanged': protected_count,
        'original_workspace_overlay_unchanged': True, 'hardware_programmed': False,
        'scope': 'Actual RTL against integer oracle; randomized behavioral DDR, one concurrent dense camera frame and display, no outer CPU/PHY cycle model. Actual RV32 ELF with modeled peripherals. Efinity map/interface/pnr/pgm. No measured board FPS.',
        'files': {p.relative_to(ROOT).as_posix(): digest(p) for p in sorted(sources)},
    }
    (RELEASE / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(f'PASS DDR release: {len(sources)} hashed files, {protected_count} protected blocks, full VGA {full["cycles"]} cycles')


if __name__ == '__main__':
    main()
