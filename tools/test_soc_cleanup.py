"""Check the active SoC cleanup and regress the real OSD enable bug."""
from pathlib import Path
import json
import os
import re
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'work/soc_cleanup_tests'
OUT.mkdir(parents=True, exist_ok=True)
IVERILOG = os.environ.get('IVERILOG', 'C:/iverilog/bin/iverilog.exe')
VVP = os.environ.get('VVP', 'C:/iverilog/bin/vvp.exe')
results = []


def simulate(name, sources, expect_failure=False):
    artifact = name + ('_negative' if expect_failure else '')
    output = OUT / (artifact + '.vvp')
    compiled = subprocess.run(
        [IVERILOG, '-g2012', '-grelative-include', '-I', 'rtl',
         '-s', name, '-o', str(output), *map(str, sources)],
        cwd=ROOT, capture_output=True, text=True, check=True)
    run = subprocess.run([VVP, str(output)], cwd=ROOT, capture_output=True,
                         text=True, timeout=30)
    (OUT / (artifact + '.log')).write_text(compiled.stderr + run.stdout + run.stderr)
    if expect_failure:
        assert run.returncode != 0 and 'disable without COMMIT failed' in run.stdout, run.stdout
        results.append('OSD negative regression: missing en2 synchronizer reproduces text-disable failure')
    else:
        assert run.returncode == 0, run.stdout + run.stderr
        results.append(run.stdout.splitlines()[0])


top = (ROOT / 'rtl/ti60f225_oob_top.v').read_text(encoding='latin1')
for instance in ('ae_controller', 'u2_i2c_master_ctrl_top', 'camera_i2c_owner_mux',
                 'ae_statistics_mailbox', 'ae_status_mailbox', 'automatic_lift',
                 'display_status_mailbox', 'osd_status_mailbox',
                 'osd_control_mailbox', 'fixed_text_osd'):
    assert not re.search(r'\b' + instance + r'\s*\(', top), instance
for removed in ('information_overlay', 'display_meter'):
    assert not re.search(r'\b' + removed + r'\s*\(', top), removed
assert 'video_display_hist' not in top and 'display_stats_valid' not in top
for instance in ('osd_db', 'startup_bars', 'startup_select', 'osd_apb'):
    assert re.search(r'\b' + instance + r'\s*\(', top), instance
project = ET.parse(ROOT / 'ti60f225_cam_hdmi.xml')
for element in project.iter():
    if element.tag.endswith('design_file'):
        name = element.get('name')
        assert not any(part in name for part in ('cam_i2c_ctrl/', 'i2c_owner_mux.sv', 'mipi_config/panel_config.v',
                                                 'hdmi_info_overlay', 'hdmi_frame_histogram', 'sc431hai_auto_exposure', 'auto_tone_lift'))
results.append('Active top/project: obsolete instances removed; HDMI histogram overlay and display meter removed; dynamic text and startup retained')

# Use the assignments from the actual top, and compare against the original
# owner mux and disabled automatic-lift module for all input combinations.
assignments = []
for name in ('io_cam_scl_OUT', 'io_cam_sda_OUT', 'io_cam_scl_OE', 'io_cam_sda_OE', 'effective_lift_strength'):
    assignments.append(re.search(r'assign\s+' + name + r'\s*=.*?;', top)[0])
equivalence = OUT / 'cleanup_equivalence_tb.sv'
equivalence.write_text('''
module cleanup_equivalence_tb;
  reg clk=0,rst_n=0;
  always #5 clk=~clk;
  reg soc_i2c_scl_out=0,soc_i2c_sda_out=0;
  reg [3:0] legacy=0;
  reg [31:0] video_display_lift=0;
  wire io_cam_scl_OUT,io_cam_sda_OUT,io_cam_scl_OE,io_cam_sda_OE;
  wire old_scl,old_sda,old_scl_oe,old_sda_oe;
  wire [7:0] effective_lift_strength,old_strength;
''' + '\n'.join(assignments) + '''
  i2c_owner_mux old_mux(.cpu_owner(1'b1),.cpu_scl_write(soc_i2c_scl_out),
    .cpu_sda_write(soc_i2c_sda_out),.legacy_scl_out(legacy[0]),.legacy_sda_out(legacy[1]),
    .legacy_scl_oe(legacy[2]),.legacy_sda_oe(legacy[3]),.scl_out(old_scl),.sda_out(old_sda),
    .scl_oe(old_scl_oe),.sda_oe(old_sda_oe));
  // Manual branch of the removed auto_tone_lift (i_enable=0), copied verbatim.
  assign old_strength=video_display_lift[15:8]>128 ? 8'd128 : video_display_lift[15:8];
  integer value,lines,prior;
  initial begin
    #2;rst_n=1;
    for(value=0;value<256;value=value+1) begin
      video_display_lift=value<<8;
      for(lines=0;lines<4;lines=lines+1) begin
        {soc_i2c_scl_out,soc_i2c_sda_out}=lines;
        for(prior=0;prior<16;prior=prior+1) begin
          legacy=prior;#1;
          if({io_cam_scl_OUT,io_cam_sda_OUT,io_cam_scl_OE,io_cam_sda_OE} !==
             {old_scl,old_sda,old_scl_oe,old_sda_oe}) $fatal(1,"camera open-drain behavior changed");
          if(effective_lift_strength!==old_strength) $fatal(1,"manual lift clamp changed");
        end
      end
    end
    $display("PASS equivalence: active-top I2C pads and all 256 manual-lift strengths match original modules");
    $finish;
  end
endmodule
''')
simulate('cleanup_equivalence_tb', [equivalence, 'rtl/soc_integration/i2c_owner_mux.sv'])

osd_sources = ['tests/osd_text_double_buffer_tb.sv',
               'rtl/soc_integration/osd_text_double_buffer.sv', 'rtl/soc_integration/osd_font8x16.sv']
simulate('osd_text_double_buffer_tb', osd_sources)
broken = OUT / 'missing_enable_sync.sv'
osd = (ROOT / osd_sources[1]).read_text()
assert osd.count('en2<=en1;') == 1
broken.write_text(osd.replace('en2<=en1;', ''))
simulate('osd_text_double_buffer_tb', [osd_sources[0], broken, osd_sources[2]], expect_failure=True)

for result in results:
    print('PASS cleanup:', result)
report = ROOT / 'reports/simulation/soc_cleanup.json'
report.write_text(json.dumps({'checks': results}, indent=2) + '\n')
