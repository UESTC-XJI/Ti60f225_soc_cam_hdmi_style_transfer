"""Regenerate the active Lite SoC with Efinity's Sapphire generator; no JTAG.
Retain unified DDR clock, lowArea=5 and existing peripheral map.
"""
from pathlib import Path
import os, subprocess, shlex, re, shutil, json, difflib
ROOT = Path(__file__).resolve().parents[1]
IP = Path(os.environ.get('EFINITY_HOME', '/home/goodmann/efinity/2026.1')) / 'ipm/ip/efx_soc/efx_soc'
SOC = ROOT / 'soc/efx_sapphire_soc/soc'
OUT = ROOT / 'work_qse_generator'

def main():
    OUT.mkdir(exist_ok=True)
    (OUT / 'hardware/netlist').mkdir(parents=True, exist_ok=True)
    bsp = OUT / 'bsp/efinix/EfxSapphireSoc'
    bsp.mkdir(parents=True, exist_ok=True)
    config = (SOC / 'source/soc_config').read_text()
    config = re.sub(r'^--ramHex .*$', '--ramHex ' + str(IP / 'generator/bootloader/bootloader_124K.hex'), config, flags=re.M)
    if 'name=system_uart_1_io' not in config:
        config += '\n--uart name=system_uart_1_io,address=0x011000,interruptId=2,fifoDepth=128\n'
    if '--noDdrAClock' not in config:
        config += '--noDdrAClock\n--lowArea 5\n'
    cmd = ['java', '-cp', str(IP / 'generator/EfxSapphireSoc.jar'), 'saxon.board.efinix.EfxSapphireSoc'] + shlex.split(config) + ['--bsp', str(bsp)]
    (OUT / 'command.json').write_text(json.dumps(cmd, indent=2))
    result = subprocess.run(cmd, cwd=OUT, capture_output=True, text=True)
    (OUT / 'generation.log').write_text(result.stdout + result.stderr)
    print(result.stdout + result.stderr)
    result.check_returncode()
    netlist = (OUT / 'hardware/netlist/EfxSapphireSoc.v').read_text()
    assert 'system_uart_1_io_rxd' in netlist
    assert 'system_ddr_ddrLogic_cc_fifo' not in netlist
    old = (SOC / 'soc.v').read_text()
    wrapper = old[:old.index('// Generator :')]
    if 'input system_uart_1_io_rxd' not in wrapper:
        wrapper = wrapper.replace('module soc\n(\n', 'module soc\n(\n    input system_uart_1_io_rxd,\n    output system_uart_1_io_txd,\n')
        wrapper = wrapper.replace('.io_systemClk ( io_systemClk ),', '.system_uart_1_io_rxd ( system_uart_1_io_rxd ),\n    .system_uart_1_io_txd ( system_uart_1_io_txd ),\n    .io_systemClk ( io_systemClk ),')
    netlist = re.sub(r'\b(EfxSapphireSoc)(?!\.v)\b', r'`IP_MODULE_NAME(\1)', netlist)
    for name in ['EfxCPUSp1.v', 'EfxCPUSp2.v']:
        netlist += '\n' + (IP / 'source_efinity' / name).read_text()
    (SOC / 'soc.v').write_text(wrapper + netlist + '\n`undef IP_UUID\n`undef IP_NAME_CONCAT\n`undef IP_MODULE_NAME\n')
    (SOC / 'source/soc_config').write_text(config)
    for file in (OUT / 'hardware/netlist').glob('*.bin'):
        shutil.copy2(file, SOC / file.name)
    # Keep the checked-in raw source used by standalone peripheral simulations
    # aligned with the compiled wrapper. Do not overwrite the customized BSP tree.
    raw = OUT / 'hardware/netlist/EfxSapphireSoc.v'
    for dest in [SOC / 'source/hardware/netlist/EfxSapphireSoc.v',
                 SOC / 'source/hardware/netlist/source_efinity/EfxSapphireSoc.v']:
        shutil.copy2(raw, dest)
    header = bsp / 'include/soc.h'
    target = ROOT / 'software/bsp/EfxSapphireSoc/include/soc.h'
    diff = ''.join(difflib.unified_diff(target.read_text().splitlines(True), header.read_text().splitlines(True), fromfile='existing BSP', tofile='generated BSP'))
    (OUT / 'bsp.diff').write_text(diff)
    print('BSP diff saved; review before synchronizing:', OUT / 'bsp.diff')

if __name__ == '__main__':
    main()
