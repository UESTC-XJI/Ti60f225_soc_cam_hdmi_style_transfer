"""Build the camera/OSD driver with the Efinity RISC-V toolchain."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
GCC = Path(r'C:/Efinity/efinity-riscv-ide-2026.1/toolchain/bin/riscv-none-elf-gcc.exe')
OBJCOPY = GCC.with_name('riscv-none-elf-objcopy.exe')
OUT = ROOT / 'work'
OUT.mkdir(exist_ok=True)
common = ['-march=rv32im','-mabi=ilp32','-ffreestanding','-fno-builtin','-Os',
          '-ffunction-sections','-fdata-sections']
def run(args): subprocess.run([str(GCC), *args], cwd=ROOT, check=True)

for suffix, extra in [('', []), ('_bsp', ['-DEFX_SAPPHIRE_BSP',
    '-Isoftware/bsp/EfxSapphireSoc/include','-Isoftware/bsp/driver'])]:
    obj=OUT/f'soc_video_driver{suffix}.o'; elf=OUT/f'soc_video_driver{suffix}.elf'; binary=OUT/f'soc_video_driver{suffix}.bin'
    run([*common,*extra,'-c','software/firmware/soc_video_driver.c','-o',str(obj)])
    run([*common,'-nostdlib','-Wl,--gc-sections,-e,camera_init_cpu',
         '-T','software/bsp/EfxSapphireSoc/linker/default.ld',str(obj),'-o',str(elf)])
    subprocess.run([str(OBJCOPY),'-O','binary',str(elf),str(binary)],cwd=ROOT,check=True)
    print(f'PASS {elf.name} and {binary.name}')
