#!/usr/bin/env bash
# 受控时域增益探针。配方照抄 runs/final/README.md §3（--chroma-blend 用用户偏好的 0.15）。
set -u
cd "$(dirname "$0")/.."

RECIPE=(--ckpt runs/D_wc_g15
  --line-source none --chroma-blend 0.15 --chroma-style great_wave --luma-match
  --flat-mode none --con 1.5 --con-auto --sat 0.85 --black-lift 0.18 --black-lift-auto
  --wc-edge 0.5 --wc-paper 0.05
  --kuwahara-aniso 1 --kuwahara-sharp 3 --kuwahara-coh 0.01 --kuwahara-down 2 --kuwahara-angles 12
  --kuwahara-guide 2 --kuwahara-guide-mode step --kuwahara-guide-eps 0.2 --kuwahara-guide-width 0.6
  --sat 1.10 --wc-sat-mid 1.30 --wc-model mul
  --wc-granule 0.30 --wc-tooth 0.15 --wc-humidity 0.16 --wc-deposit 0.25 --wc-deposit-thr 0.05)

echo "########## ① real：定稿配方 ##########"
python -m tools.td_gain --mode real --limit 4 -- "${RECIPE[@]}" 2>&1 | tail -12

echo
echo "########## ② real：关掉颗粒（granule 0.30 -> 0） ##########"
python -m tools.td_gain --mode real --limit 4 -- "${RECIPE[@]}" --wc-granule 0 2>&1 | tail -10

echo
echo "########## ③ real：纸纹组全关（对照 flicker 的 -57%） ##########"
python -m tools.td_gain --mode real --limit 4 -- "${RECIPE[@]}" \
  --wc-paper 0 --wc-granule 0 --wc-tooth 0 --wc-humidity 0 --wc-deposit 0 2>&1 | tail -10

echo
echo "########## ④ uniform / noise / local（δ=1/255，说明各档语义） ##########"
for m in uniform noise local; do
  echo "--- $m ---"
  python -m tools.td_gain --mode $m --delta 1.0 --limit 3 -- "${RECIPE[@]}" 2>&1 | sed -n '/^\*\*平均/p'
done
