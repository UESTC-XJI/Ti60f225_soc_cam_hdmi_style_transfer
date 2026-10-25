#!/bin/bash
# Build the Sapphire video application by calling the RISC-V toolchain directly.
# The Python wrapper (build_firmware.py) goes through a subprocess shim that
# crashes this toolchain with exit 0xC0000409, so the compiler is invoked from
# the shell instead.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/software/firmware"
OUT="$APP/build"
TC="${SOC_RISCV_TOOLCHAIN:-D:/Efinity/efinity-riscv-ide-2026.1/toolchain/bin}"
GCC="$TC/riscv-none-elf-gcc.exe"
OBJCOPY="$TC/riscv-none-elf-objcopy.exe"
SIZE="$TC/riscv-none-elf-size.exe"
mkdir -p "$OUT"
COMMON=(-march=rv32im_zicsr_zifencei -mabi=ilp32 -msmall-data-limit=0
        -ffreestanding -fno-builtin -Os -g3 -ffunction-sections -fdata-sections
        -DEFX_SAPPHIRE_BSP -Isoftware/bsp/EfxSapphireSoc/include -Isoftware/bsp/driver)
cd "$ROOT"
OBJS=()
for s in start.S main.c soc_video_driver.c video_ctrl.c video_stats.c camera_ae.c camera_awb.c camera_3a.c style_driver.c; do
  o="$OUT/${s%.*}.o"
  echo "  CC $s"
  "$GCC" "${COMMON[@]}" -c "$APP/$s" -o "$o"
  OBJS+=("$o")
done
echo "  LD soc_video_app.elf"
"$GCC" "${COMMON[@]}" -nostdlib -Wl,--gc-sections,--no-undefined \
  "-Wl,-Map,$OUT/soc_video_app.map" -T "$APP/app.ld" "${OBJS[@]}" -lgcc -o "$OUT/soc_video_app.elf"
"$OBJCOPY" -O binary "$OUT/soc_video_app.elf" "$OUT/soc_video_app.bin"
echo ""
"$SIZE" "$OUT/soc_video_app.elf"
echo "PASS complete application: $OUT/soc_video_app.elf"
