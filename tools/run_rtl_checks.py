"""Run feature and baseline regression checks against this worktree only."""
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
TESTS = ROOT / 'tests'
BUILD = ROOT / 'work' / 'rtl_checks'
IVERILOG = os.environ.get('IVERILOG', 'C:/iverilog/bin/iverilog.exe')
VVP = os.environ.get('VVP', 'C:/iverilog/bin/vvp.exe')

def run(top, sources, extra=()):
    output = BUILD / (top + '.vvp')
    subprocess.run([IVERILOG, '-g2012', '-I', str(ROOT / 'rtl'), '-I', str(ROOT / 'rtl/isp'),
                    '-s', top, '-o', str(output), *extra,
                    *map(str, sources)], check=True, cwd=ROOT)
    subprocess.run([VVP, str(output)], check=True, timeout=60, cwd=ROOT)

if __name__ == '__main__':
    BUILD.mkdir(parents=True, exist_ok=True)
    isp = ROOT / 'rtl/isp'
    run('hdmi_overlay_tb', [TESTS / 'hdmi_overlay_tb.v', isp / 'hdmi_info_overlay.v', isp / 'hdmi_frame_histogram.v'])
    run('hdmi_overlay_tb', [TESTS / 'hdmi_overlay_tb.v', isp / 'hdmi_info_overlay.v', isp / 'hdmi_frame_histogram.v'], ['-Phdmi_overlay_tb.FULL=1'])
    run('hdmi_overlay_apb_tb', [TESTS / 'hdmi_overlay_apb_tb.v', isp / 'hdmi_info_overlay_apb.v'])
    run('highlight_stats_tb', [TESTS / 'highlight_stats_tb.v', isp / 'ae_frame_stats.v'])
    run('highlight_stats_tb', [TESTS / 'highlight_stats_tb.v', isp / 'ae_frame_stats.v'], ['-Phighlight_stats_tb.FULL=1'])
    run('luma_lift_tb', [TESTS / 'luma_lift_tb.v', isp / 'luma_tone_map.v'])
    run('luma_lift_tb', [TESTS / 'luma_lift_tb.v', isp / 'luma_tone_map.v'], ['-Pluma_lift_tb.SAFE=1'])
    run('auto_lift_tb', [TESTS / 'auto_lift_tb.v', isp / 'auto_tone_lift.v', isp / 'luma_tone_map.v', isp / 'ae_frame_stats.v'])
    run('highlight_ae_tb', [TESTS / 'highlight_ae_tb.v', isp / 'sc431hai_auto_exposure.v'])
    run('ae_stability_tb', [TESTS / 'ae_stability_tb.v', isp / 'sc431hai_auto_exposure.v'])
    run('fixed_stability_tb', [TESTS / 'fixed_stability_tb.v', isp / 'sc431hai_auto_exposure.v'])
    run('fixed_ae_tb', [TESTS / 'fixed_ae_tb.v', isp / 'sc431hai_auto_exposure.v'])
    run('predictive_ae_tb', [TESTS / 'predictive_ae_tb.v', isp / 'sc431hai_auto_exposure.v'])
    run('ae_controller_tb', [TESTS / 'ae_controller_tb.v', isp / 'sc431hai_auto_exposure.v'])
    run('tone_tb', [TESTS / 'legacy_tone_mailbox_tb.v', isp / 'luma_color_suppress.v'])
    run('mailbox_tb', [TESTS / 'legacy_tone_mailbox_tb.v', isp / 'isp_cdc_mailbox.v'])
    i2c = ROOT / 'rtl/cam_i2c_ctrl'
    run('i2c_runtime_tb', [TESTS / 'i2c_runtime_tb.v', isp / 'sc431hai_auto_exposure.v',
        *sorted((i2c / 'i2c').glob('*.v')), *sorted((i2c / 'i2c_master').glob('*.v'))],
        ['-I', str(i2c / 'i2c_master')])
    debayer = ROOT / 'rtl/debayer'
    run('ae_camera_stats_tb', [TESTS / 'ae_camera_stats_tb.v', isp / 'ae_frame_stats.v',
        *[debayer / p for p in ('debayer_top_2to1.v', 'rgb_gain_v1.v', 'line_buffer.v', 'raw_to_rgb.v')],
        ROOT / 'rtl/true_dual_port_ram.v'])
