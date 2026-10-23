"""QSE pin contract and simulation regressions (no board access)."""
from pathlib import Path
import json, subprocess, tempfile, os, xml.etree.ElementTree as ET
ROOT = Path(__file__).resolve().parents[1]

def main():
    subprocess.run(['python', str(ROOT / 'tools/test_compact_font.py')],
                   cwd=ROOT, env={**os.environ, 'IVERILOG':'/usr/bin/iverilog','VVP':'/usr/bin/vvp'}, check=True)
    peri = ET.parse(ROOT / 'ti60f225_oob.peri.xml').getroot()
    gpios = {e.get('name'): e for e in peri.iter() if e.tag.endswith('comp_gpio')}
    for name, pin, pull in [('io_sw1','GPIOL_04','weak pullup'),('io_sw2','GPIOL_10','weak pullup'),('io_key0','GPIOL_11','weak pulldown'),('io_key1','GPIOL_09','weak pulldown'),('ble_uart_rxd','GPIOL_06','weak pullup'),('ble_uart_txd','GPIOR_13',None)]:
        e = gpios[name]
        assert e.get('gpio_def') == pin
        assert e.get('io_standard') == '3.3 V LVCMOS'
        assert list(e)[0].get('pull_option') == pull
    assert list(gpios['ble_uart_txd'])[0].get('drive_strength') == '2'
    assert gpios['system_uart_0_io_rxd'].get('gpio_def') == 'GPIOL_02'
    assert gpios['system_uart_0_io_txd'].get('gpio_def') == 'GPIOR_28'
    conf = json.loads((ROOT / 'soc/efx_sapphire_soc/soc/settings.json').read_text())['conf']
    assert conf['UART1'] == "1'b1" and conf['UART1_FIFODEPTH'] == '128'
    assert conf['UART1_INT_ID'] == '2' and conf['DDRCLK_DOMAIN'] == '1'
    project = ET.parse(ROOT / 'ti60f225_cam_hdmi.xml').getroot()
    files = [e.get('name') for e in project.iter() if e.tag.endswith('design_file')]
    assert 'rtl/soc_integration/qse_gpio_sync.sv' in files
    assert 'rtl/soc_oob/top_soc_oob.v' not in files
    print('PASS pin/pull/voltage contract, UART0 preserved, UART1 config, active project sources')
    raw = ROOT / 'soc/efx_sapphire_soc/soc/source/hardware/netlist/EfxSapphireSoc.v'
    with tempfile.TemporaryDirectory(prefix='qse_', dir=os.environ.get('TMPDIR')) as tmp:
        for tb, rtl in [('qse_gpio_tb', ROOT / 'rtl/soc_integration/qse_gpio_sync.sv'), ('qse_uart_tb', raw),
                        ('qse_ui_tb', ROOT / 'rtl/soc_integration/qse_ui_control.sv'),
                        ('qse_osd_tb', ROOT / 'rtl/soc_integration/osd_text_double_buffer.sv'),
                        ('qse_label_pixels_tb', ROOT / 'rtl/soc_integration/osd_text_double_buffer.sv'),
                        ('qse_display_mode_tb', ROOT / 'rtl/style/style_display.sv'),
                        ('qse_display_frames_tb', ROOT / 'rtl/style/style_display.sv')]:
            exe = str(Path(tmp) / (tb + '.vvp'))
            extra = []
            if tb == 'qse_ui_tb':
                extra = [ROOT / 'rtl/soc_integration/qse_gpio_sync.sv']
            elif tb in ['qse_osd_tb', 'qse_label_pixels_tb']:
                extra = [ROOT / 'rtl/soc_integration/osd_font8x16.sv']
            elif tb.startswith('qse_display_'):
                extra = [ROOT / ('rtl/style/' + name + '.sv') for name in ['style_async_fifo', 'style_axi_rows', 'style_display_beats']]
            subprocess.run(['iverilog','-g2012','-s',tb,'-o',exe,str(ROOT / 'tests' / (tb + '.sv')),str(rtl), *map(str, extra)], check=True)
            subprocess.run(['vvp',exe], check=True)

if __name__ == '__main__':
    main()
