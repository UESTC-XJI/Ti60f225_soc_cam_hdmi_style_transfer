"""Build the complete JTAG-downloadable Sapphire video application."""
from pathlib import Path
import os
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'software/firmware'
OUT = APP / 'build'
TOOLCHAIN = Path(os.environ.get('SOC_RISCV_TOOLCHAIN',
    'C:/Efinity/efinity-riscv-ide-2026.1/toolchain/bin'))
GCC = TOOLCHAIN / ('riscv-none-elf-gcc.exe' if os.name == 'nt' else 'riscv-none-elf-gcc')
COMMON = ['-march=rv32im_zicsr_zifencei', '-mabi=ilp32', '-msmall-data-limit=0',
          '-ffreestanding', '-fno-builtin', '-Os', '-g3',
          '-ffunction-sections', '-fdata-sections',
          '-DEFX_SAPPHIRE_BSP', '-Isoftware/bsp/EfxSapphireSoc/include',
          '-Isoftware/bsp/driver']

def run(exe, *args):
    subprocess.run([str(exe), *map(str, args)], cwd=ROOT, check=True)

def main():
    if '--clean' in sys.argv:
        if OUT.exists():
            for path in OUT.iterdir():
                if path.is_file(): path.unlink()
        return
    OUT.mkdir(exist_ok=True)
    objects = []
    for source in ['start.S', 'main.c', 'soc_video_driver.c', 'video_ctrl.c', 'video_stats.c',
                   'camera_ae.c', 'camera_awb.c', 'camera_3a.c', 'style_driver.c']:
        obj = OUT / (Path(source).stem + '.o')
        run(GCC, *COMMON, '-c', APP / source, '-o', obj)
        objects.append(obj)
    elf = OUT / 'soc_video_app.elf'
    run(GCC, *COMMON, '-nostdlib', '-Wl,--gc-sections,--no-undefined',
        '-Wl,-Map,' + (OUT / 'soc_video_app.map').as_posix(),
        '-T', APP / 'app.ld', *objects, '-lgcc', '-o', elf)
    run(TOOLCHAIN / ('riscv-none-elf-objcopy' + ('.exe' if os.name == 'nt' else '')), '-O', 'binary', elf,
        OUT / 'soc_video_app.bin')
    run(TOOLCHAIN / ('riscv-none-elf-size' + ('.exe' if os.name == 'nt' else '')), elf)
    print('PASS complete application:', elf)

if __name__ == '__main__': main()
