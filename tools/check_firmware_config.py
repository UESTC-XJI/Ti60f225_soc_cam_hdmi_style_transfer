"""Validate IDE attributes and parse OpenOCD settings without accessing a board."""
from pathlib import Path
import re
import subprocess
from xml.etree import ElementTree as ET
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'software/firmware'
IDE = Path('C:/Efinity/efinity-riscv-ide-2026.1')
project = ET.parse(APP / '.project').getroot().findtext('name')
assert project == 'soc_video_app'
ET.parse(APP / '.cproject')
launch = ET.parse(APP / 'soc_video_app_ti.launch').getroot()
attrs = {e.attrib['key']: e.attrib['value'] for e in launch}
assert attrs['org.eclipse.cdt.launch.PROJECT_ATTR'] == project
assert (APP / attrs['org.eclipse.cdt.launch.PROGRAM_NAME']).is_file()
assert attrs['org.eclipse.cdt.debug.gdbjtag.core.stopAt'] == 'main'
assert attrs['ilg.gnumcueclipse.debug.gdbjtag.openocd.otherRunCommands'] == 'set $pc = _start'
jar = next((IDE / 'Efinity-RISCV-IDE/plugins').glob('*openocd.core_*.jar'))
with ZipFile(jar) as z:
    assert launch.attrib['type'] in z.read('plugin.xml').decode()
    constants = z.read('org/eclipse/embedcdt/debug/gdbjtag/openocd/core/ConfigurationAttributes.class')
    for key in attrs:
        if key.startswith('ilg.gnumcueclipse.'):
            assert key.encode() in constants, 'Unknown IDE launch attribute: ' + key
for key in ['org.eclipse.cdt.dsf.gdb.DEBUG_NAME',
            'ilg.gnumcueclipse.debug.gdbjtag.openocd.gdbServerExecutable']:
    path = attrs[key].replace('${eclipse_home}', (IDE / 'Efinity-RISCV-IDE').as_posix())
    assert Path(path).is_file(), path

# The real configuration is parsed by the installed vendor OpenOCD.
# Omit init/halt to prevent USB/JTAG access. All target/mapping/YAML commands run.
cfg = (APP / 'openocd/soc_video.cfg').read_text()
cfg = re.sub(r'^set app_dir .*$', 'set app_dir {' + APP.as_posix() + '}', cfg, flags=re.M)
cfg = '\n'.join(line for line in cfg.splitlines() if line.strip() not in ('init', 'halt')) + '\n'
out = ROOT / 'work/openocd_parse_check.cfg'
out.parent.mkdir(exist_ok=True)
out.write_text(cfg)
result = subprocess.run([str(IDE / 'openocd/bin/openocd.exe'), '-f', str(out), '-c', 'shutdown'],
                        capture_output=True, text=True)
assert result.returncode == 0, result.stdout + result.stderr
print('PASS IDE XML, installed launch attributes, executable/ELF paths, native USER1 OpenOCD/YAML parsing')
print('Hardware init/halt deliberately omitted in this static configuration check.')
