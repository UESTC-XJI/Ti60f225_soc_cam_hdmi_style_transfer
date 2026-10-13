#!/usr/bin/env bash
# 时域抖动的**留一法消融**：从定稿配方里各拿掉一组算子，看抖动掉多少。
# 直接跑：bash tools/_ab_flicker.sh
set -u
cd "$(dirname "$0")/.."

COMMON=(--ckpt runs/D_wc_g15 --input runs/VIDEO_material --limit 99 --max-side 0 --dump-panels
  --line-source none --chroma-blend 0.15 --chroma-style great_wave --luma-match
  --flat-mode none --con 1.5 --con-auto --sat 0.85 --black-lift 0.18 --black-lift-auto
  --wc-edge 0.5 --wc-paper 0.05
  --kuwahara-aniso 1 --kuwahara-sharp 3 --kuwahara-coh 0.01 --kuwahara-down 2 --kuwahara-angles 12
  --kuwahara-guide 2 --kuwahara-guide-mode step --kuwahara-guide-eps 0.2 --kuwahara-guide-width 0.6
  --sat 1.10 --wc-sat-mid 1.30 --wc-model mul
  --wc-granule 0.30 --wc-tooth 0.15 --wc-humidity 0.16 --wc-deposit 0.25 --wc-deposit-thr 0.05)

# noK —— 拿掉 Kuwahara（笔触）
python -m tools.toon "${COMMON[@]}" --kuwahara-aniso 0 --kuwahara 0 --out runs/_ab_noK >/dev/null 2>&1
# noP —— 拿掉纸纹（wc-* 全部归零）
python -m tools.toon "${COMMON[@]}" --wc-paper 0 --wc-granule 0 --wc-tooth 0 --wc-humidity 0 \
  --wc-deposit 0 --out runs/_ab_noP >/dev/null 2>&1
# noC —— 拿掉对比度增益（1.5 → 1.0）
python -m tools.toon "${COMMON[@]}" --con 1.0 --con-auto --out runs/_ab_noC >/dev/null 2>&1

for t in _ab_noK _ab_noP _ab_noC; do
  echo "===== $t ====="
  python -m tools.flicker --content runs/VIDEO_material --stages "runs/$t" --out "runs/view_big/AB_FK/$t" 2>&1 | sed -n '/^|/p'
done
