"""Validate IDE attributes and parse OpenOCD settings without accessing a board."""
from pathlib import Path
import subprocess
from xml.etree import ElementTree as ET
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'software/firmware'
IDE = Path('C:/Efinity/efinity-riscv-ide-2026.1')
project = ET.parse(APP / '.project').getroot().findtext('name')
assert project == 'soc_video_app'
cproject = ET.parse(APP / '.cproject')
assert cproject.find('.//extension[@id="org.eclipse.cdt.core.ELF"]') is not None
launch = ET.parse(APP / 'soc_video_app_ti.launch').getroot()
attrs = {e.attrib['key']: e.attrib['value'] for e in launch if 'value' in e.attrib}
assert attrs['org.eclipse.cdt.launch.PROJECT_ATTR'] == project
binary = attrs['org.eclipse.cdt.launch.PROGRAM_NAME']
if binary.startswith('${workspace_loc:/soc_video_app/'):
    binary = binary.replace('${workspace_loc:/soc_video_app/', APP.as_posix() + '/').removesuffix('}')
binary_path = Path(binary)
if not binary_path.is_absolute(): binary_path = APP / binary_path
assert binary_path.is_file(), binary_path
assert binary_path.read_bytes()[:4] == b'\x7fELF'
assert attrs['org.eclipse.cdt.debug.gdbjtag.core.stopAt'] == '*main'
assert attrs['ilg.gnumcueclipse.debug.gdbjtag.openocd.otherInitCommands'] == 'monitor reset halt'
assert 'set riscv use-compressed-breakpoints no' in attrs['ilg.gnumcueclipse.debug.gdbjtag.openocd.gdbClientOtherCommands']
assert attrs['ilg.gnumcueclipse.debug.gdbjtag.openocd.otherRunCommands'] == 'set $pc = _start'
jar = next((IDE / 'Efinity-RISCV-IDE/plugins').glob('*openocd.core_*.jar'))
with ZipFile(jar) as z:
    assert launch.attrib['type'] in z.read('plugin.xml').decode()
    constants = z.read('org/eclipse/embedcdt/debug/gdbjtag/openocd/core/ConfigurationAttributes.class')
    for key in attrs:
        if key.startswith('ilg.gnumcueclipse.debug.gdbjtag.openocd.'):
            assert key.encode() in constants, 'Unknown IDE launch attribute: ' + key
for key in ['org.eclipse.cdt.dsf.gdb.DEBUG_NAME',
            'ilg.gnumcueclipse.debug.gdbjtag.openocd.gdbServerExecutable']:
    path = attrs[key].replace('${eclipse_home}', (IDE / 'Efinity-RISCV-IDE').as_posix())
    assert Path(path).is_file(), path

# Execute the original configuration; never replace its path-resolution logic.
# SOC_CONFIG_CHECK bypasses only hardware init/halt, not source/target/YAML setup.
cfg = APP / 'openocd/soc_video.cfg'
for cwd, cfg_path in [(ROOT, str(cfg)), (ROOT, str(APP) + '/openocd/soc_video.cfg'),
                      (APP, cfg.as_posix()),
                      (APP, 'openocd/soc_video.cfg')]:
    result = subprocess.run([str(IDE / 'openocd/bin/openocd.exe'),
                            '-c', 'set SOC_CONFIG_CHECK 1', '-f', cfg_path, '-c', 'shutdown'],
                           cwd=cwd, capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr
    assert 'SOC configuration check: init/halt skipped' in result.stdout + result.stderr
print('PASS IDE XML, installed launch attributes, executable/ELF paths, native USER1 OpenOCD/YAML parsing')
print('PASS original OpenOCD file with Windows/mixed/forward-slash absolute paths and relative path.')
print('SOC_CONFIG_CHECK skips hardware init/halt only; no board access.')
