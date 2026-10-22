"""Test the imported, unmodified Sapphire I2C controller against a wire slave."""
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
netlist = ROOT / 'soc/efx_sapphire_soc/soc/source/hardware/netlist/source_efinity/EfxSapphireSoc.v'
source = netlist.read_text()
out = ROOT / 'work/sapphire_i2c_ack'
out.mkdir(parents=True, exist_ok=True)
# Extract only these intact modules; the CPU/cache netlist is not simulated.
modules = [re.search(r'^module ' + name + r'\b.*?^endmodule', source, re.M | re.S)[0]
           for name in ('BmbI2cCtrl', 'I2cSlave', 'BufferCC_20')]
rtl = out / 'native_i2c.v'
rtl.write_text('`timescale 1ns/1ps\n' + '\n'.join(modules))
exe = out / 'test.vvp'
subprocess.run(['C:/iverilog/bin/iverilog.exe', '-g2012', '-s', 'sapphire_i2c_ack_tb',
                '-o', str(exe), str(rtl), str(ROOT / 'tests/sapphire_i2c_ack_tb.sv')], check=True)
subprocess.run(['C:/iverilog/bin/vvp.exe', str(exe)], check=True, timeout=60)
