#!/usr/bin/env bash
# Build software/firmware with the Efinity RISC-V IDE toolchain.
# Usage: tools/build_firmware.sh [--clean]
# Toolchain lookup: $SOC_RISCV_TOOLCHAIN, else $EFINITY_RISCV_IDE/toolchain/bin,
# else the newest ~/efinity/efinity-riscv-ide-*/toolchain/bin.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -z "${SOC_RISCV_TOOLCHAIN:-}" ]]; then
    if [[ -n "${EFINITY_RISCV_IDE:-}" ]]; then
        SOC_RISCV_TOOLCHAIN="$EFINITY_RISCV_IDE/toolchain/bin"
    else
        SOC_RISCV_TOOLCHAIN="$(ls -d "$HOME"/efinity/efinity-riscv-ide-*/toolchain/bin 2>/dev/null | sort -V | tail -n1 || true)"
    fi
fi

if [[ ! -x "${SOC_RISCV_TOOLCHAIN:-}/riscv-none-elf-gcc" ]]; then
    echo "riscv-none-elf-gcc not found; set SOC_RISCV_TOOLCHAIN or EFINITY_RISCV_IDE" >&2
    exit 1
fi
export SOC_RISCV_TOOLCHAIN
echo "Toolchain: $SOC_RISCV_TOOLCHAIN"

python3 "$root/tools/build_firmware.py" "$@"
