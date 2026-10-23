"""Run with Efinity Python after sourcing bin/setup.sh. Uses Interface Designer API."""
import os, sys
from pathlib import Path
sys.path.append(os.environ['EFXPT_HOME'] + '/bin')
from api_service.design import DesignAPI
root = Path(__file__).resolve().parents[1]
d = DesignAPI(is_verbose=True)
d.load(str(root / 'ti60f225_oob.peri.xml'))
for name, pin, pull in [('io_sw1','GPIOL_04','WEAK_PULLUP'),('io_sw2','GPIOL_10','WEAK_PULLUP'),('io_key0','GPIOL_11','WEAK_PULLDOWN'),('io_key1','GPIOL_09','WEAK_PULLDOWN'),('ble_uart_rxd','GPIOL_06','WEAK_PULLUP')]:
    if d.get_gpio(name) is None:
        d.create_input_gpio(name)
    d.assign_resource(name, pin)
    d.set_property(name, 'IO_STANDARD', '3.3 V LVCMOS')
    d.set_property(name, 'PULL_OPTION', pull)
if d.get_gpio('ble_uart_txd') is None:
    d.create_output_gpio('ble_uart_txd')
d.assign_resource('ble_uart_txd', 'GPIOR_13')
d.set_property('ble_uart_txd', 'IO_STANDARD', '3.3 V LVCMOS')
d.set_property('ble_uart_txd', 'DRIVE_STRENGTH', '2')
assert d.check_design(), str(d.get_design_check_issue(True))
d.save()
print('PASS Interface Designer QSE pins, pulls and bank validation')
