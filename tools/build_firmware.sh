#!/bin/bash
# Rebuild the Sapphire video application firmware.
# The Python wrapper's subprocess shim crashes this toolchain (exit 0xC0000409),
# so invoke the compiler directly from bash instead.
set -e

TC="/d/Efinity/efinity-riscv-ide-2026.1/toolchain/bin"
GCC="$TC/riscv-none-elf-gcc.exe"
OBJCOPY="$TC/riscv-none-elf-objcopy.exe"
SIZE="$TC/riscv-none-elf-size.exe"

ROOT="C:/Users/36040/Downloads/Ti60F225_DemoBoard_v4/demo"
APP="$ROOT/software/firmware"
OUT="$APP/build"

COMMON=(-march=rv32im_zicsr_zifencei -mabi=ilp32 -msmall-data-limit=0
        -ffreestanding -fno-builtin -Os -g3
        -ffunction-sections -fdata-sections
        -DEFX_SAPPHIRE_BSP
        -Isoftware/bsp/EfxSapphireSoc/include
        -Isoftware/bsp/driver)

cd "$ROOT"
mkdir -p "$OUT"

OBJS=()
for src in start.S main.c soc_video_driver.c video_ctrl.c video_stats.c \
           camera_ae.c camera_awb.c camera_3a.c style_driver.c; do
  obj="$OUT/$(basename "$src" | sed 's/\.[^.]*$//').o"
  echo "  CC  $src"
  "$GCC" "${COMMON[@]}" -c "$APP/$src" -o "$obj"
  OBJS+=("$obj")
done

echo "  LD  soc_video_app.elf"
"$GCC" "${COMMON[@]}" -nostdlib -Wl,--gc-sections,--no-undefined \
  "-Wl,-Map,$OUT/soc_video_app.map" \
  -T "$APP/app.ld" "${OBJS[@]}" -lgcc -o "$OUT/soc_video_app.elf"

echo "  OBJCOPY soc_video_app.bin"
"$OBJCOPY" -O binary "$OUT/soc_video_app.elf" "$OUT/soc_video_app.bin"

echo "  SIZE"
"$SIZE" "$OUT/soc_video_app.elf"
echo "PASS complete application: $OUT/soc_video_app.elf"
