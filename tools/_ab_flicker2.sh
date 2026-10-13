#!/usr/bin/env bash
# 时域抖动：把「纸纹组」内部的 5 个算子逐个拿掉，定位是谁在放大逐帧差。
# 第一轮已确定：去掉整组抖动 6.09 -> 2.62（-57%），Kuwahara 只占 8%。
set -u
cd "$(dirname "$0")/.."

BASE=(--ckpt runs/D_wc_g15 --input runs/VIDEO_material --limit 99 --max-side 0 --dump-panels
  --line-source none --chroma-blend 0.15 --chroma-style great_wave --luma-match
  --flat-mode none --con 1.5 --con-auto --sat 0.85 --black-lift 0.18 --black-lift-auto
  --wc-edge 0.5 --wc-paper 0.05
  --kuwahara-aniso 1 --kuwahara-sharp 3 --kuwahara-coh 0.01 --kuwahara-down 2 --kuwahara-angles 12
  --kuwahara-guide 2 --kuwahara-guide-mode step --kuwahara-guide-eps 0.2 --kuwahara-guide-width 0.6
  --sat 1.10 --wc-sat-mid 1.30 --wc-model mul
  --wc-granule 0.30 --wc-tooth 0.15 --wc-humidity 0.16 --wc-deposit 0.25 --wc-deposit-thr 0.05)

python -m tools.toon "${BASE[@]}" --wc-paper 0        --out runs/_ab_paper    >/dev/null 2>&1
python -m tools.toon "${BASE[@]}" --wc-granule 0      --out runs/_ab_granule  >/dev/null 2>&1
python -m tools.toon "${BASE[@]}" --wc-tooth 0        --out runs/_ab_tooth    >/dev/null 2>&1
python -m tools.toon "${BASE[@]}" --wc-humidity 0     --out runs/_ab_humidity >/dev/null 2>&1
python -m tools.toon "${BASE[@]}" --wc-deposit 0      --out runs/_ab_deposit  >/dev/null 2>&1

for t in paper granule tooth humidity deposit; do
  echo "===== 去掉 $t ====="
  python -m tools.flicker --content runs/VIDEO_material --stages "runs/_ab_$t" \
    --out "runs/view_big/AB_FK2/$t" 2>&1 | sed -n '/^|/p'
done
