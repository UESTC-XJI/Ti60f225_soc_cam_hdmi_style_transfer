#!/bin/bash
# Build the Sapphire video application by calling the RISC-V toolchain directly.
# The Python wrapper (build_firmware.py) goes through a subprocess shim that
# crashes this toolchain with exit 0xC0000409, so the compiler is invoked from
# the shell instead.
#
# ---------------------------------------------------------------------------
# 用法：
#   bash tools/build_firmware.sh                 # 用当前 software/firmware/rowpipe_weights.h
#   bash tools/build_firmware.sh redsky_v5       # ← 推荐：点名风格，脚本自己去导出目录取权重
#   bash tools/build_firmware.sh /abs/path/to/rowpipe_weights.h
#
# 为什么要有"点名风格"这个用法（2026-10-27）：
#   `software/firmware/rowpipe_weights.h` 实质上是个**构建产物** —— 它每次换风格
#   都会被整个覆盖。模型侧如果直接手改它，就会和这边的构建撞车：撞了不报错，
#   只是固件里静悄悄变成别的权重（实测发生过一次，15:03 被改成原版
#   0xc7eaf900，而当时正在构建 redsky v5）。
#
#   所以约定：**模型侧只写自己的导出目录**（demo/reports/rowpipe/export_<风格>/），
#   构建时点名即可，不要手改 firmware 下那份。
# ---------------------------------------------------------------------------
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/software/firmware"
OUT="$APP/build"
EXPORT_ROOT="${ROWPIPE_EXPORT_ROOT:-$ROOT/../demo/reports/rowpipe}"
TC="${SOC_RISCV_TOOLCHAIN:-D:/Efinity/efinity-riscv-ide-2026.1/toolchain/bin}"
GCC="$TC/riscv-none-elf-gcc.exe"
OBJCOPY="$TC/riscv-none-elf-objcopy.exe"
SIZE="$TC/riscv-none-elf-size.exe"
mkdir -p "$OUT"

# ---- 可选：点名风格 → 从导出目录同步权重 ----
STYLE_ARG="$1"
WEIGHTS="$APP/rowpipe_weights.h"
if [ -n "$STYLE_ARG" ]; then
  if [ -f "$STYLE_ARG" ]; then
    SRC="$STYLE_ARG"
  elif [ -f "$EXPORT_ROOT/$STYLE_ARG/rowpipe_weights.h" ]; then
    SRC="$EXPORT_ROOT/$STYLE_ARG/rowpipe_weights.h"
  elif [ -f "$EXPORT_ROOT/export_$STYLE_ARG/rowpipe_weights.h" ]; then
    SRC="$EXPORT_ROOT/export_$STYLE_ARG/rowpipe_weights.h"
  elif [ -f "$EXPORT_ROOT/export_${STYLE_ARG%%_*}/${STYLE_ARG##*_}/rowpipe_weights.h" ]; then
    # 支持嵌套命名：starry_g075 → export_starry/g075/
    SRC="$EXPORT_ROOT/export_${STYLE_ARG%%_*}/${STYLE_ARG##*_}/rowpipe_weights.h"
  else
    echo "找不到风格 '$STYLE_ARG'：既不是文件，也不在 $EXPORT_ROOT/{,export_}$STYLE_ARG/ 下" >&2
    echo "可用风格：" >&2
    ls -d "$EXPORT_ROOT"/export_* 2>/dev/null | sed 's|.*/export_|  |' >&2
    exit 2
  fi
  cp "$SRC" "$WEIGHTS"
  echo "  权重 <- $SRC"
fi

# ---- 构建前打印权重身份：固件到底装了哪套，一眼可查 ----
XOR=$(grep -m1 'ROWPIPE_WEIGHT_XOR' "$WEIGHTS" | grep -oE '0x[0-9a-fA-F]+' || echo '?')
WORDS=$(grep -m1 'ROWPIPE_WEIGHT_WORDS' "$WEIGHTS" | grep -oE '[0-9]+' || echo '?')
echo "  权重：XOR=$XOR  WORDS=$WORDS  （$WEIGHTS）"
# 标签里带末层约定：signed = qlo<0（正确）；offset = qlo=0（靠 RTL 兜底）
case "$XOR" in
  0xcbc67865) echo "         ^ redsky v5（呐喊）                        [signed ✅]" ;;
  0x4a18e91c) echo "         ^ ink v5                                   [signed ✅]" ;;
  0x58979045) echo "         ^ wave v5                                  [signed ✅]" ;;
  0x633d80ce) echo "         ^ wave v6                                  [见 q 头]" ;;
  0x7296f3e8) echo "         ^ starry v8 signed                         [signed ✅]" ;;
  0x72e97318) echo "         ^ starry v8                                [offset ⚠]" ;;
  0x66ac227e) echo "         ^ starry v7 signed                         [signed ✅]" ;;
  0x66ad16b1) echo "         ^ starry v7 signed + 板侧 DC 固化              [signed ✅]" ;;
  0x7296bfce) echo "         ^ starry v8 signed + 板侧 DC 固化              [signed ✅]" ;;
  0xb995616f) echo "         ^ starry old signed + 板侧 DC 固化             [signed ✅]" ;;
  0xc9aefbc3) echo "         ^ red_v3 + 板侧 DC 固化 (呐喊红调)      [signed ✅]" ;;
  0xd0593c46) echo "         ^ red_v3 (饱和修正) + 板侧 DC 固化   [signed ✅]" ;;
  0x6190ec6f) echo "         ^ starry v7                                [offset ⚠]" ;;
  0xb99505f9) echo "         ^ starry old signed                        [signed ✅]" ;;
  0xb987a435) echo "         ^ starry old                               [offset ⚠]" ;;
  0x5a9190f5) echo "         ^ starry v4                                [offset ⚠]" ;;
  0x511c3201) echo "         ^ starry v3                                [offset ⚠]" ;;
  0xa2f48f43) echo "         ^ starry v2                                [offset ⚠]" ;;
  0x248752c6) echo "         ^ starry v1                                [offset ⚠]" ;;
  0xf6a82050) echo "         ^ starry g075                              [offset ⚠]" ;;
  0xcdc157c0) echo "         ^ starry g085                              [offset ⚠]" ;;
  0xc7eaf900) echo "         ^ ⚠ cap8-starry 原始 blob（不是 v5 家族，确认是有意的）" ;;
  0x9277287c) echo "         ^ starry xxg640 v2 + 原版图 DC（sn_dc）      [signed ✅]" ;;
  *)          echo "         ^ 未登记的风格，请核对" ;;
esac

COMMON=(-march=rv32im_zicsr_zifencei -mabi=ilp32 -msmall-data-limit=0
        -ffreestanding -fno-builtin -Os -g3 -ffunction-sections -fdata-sections
        -DBLE_SILENT_UART
        -DEFX_SAPPHIRE_BSP -Isoftware/bsp/EfxSapphireSoc/include -Isoftware/bsp/driver)
cd "$ROOT"
OBJS=()
for s in start.S main.c soc_video_driver.c video_ctrl.c video_stats.c camera_ae.c camera_awb.c camera_3a.c style_driver.c qse_ble.c qse_imgtx.c qse_jpeg.c; do
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
echo "PASS complete application: $OUT/soc_video_app.elf  [weights XOR=$XOR]"
