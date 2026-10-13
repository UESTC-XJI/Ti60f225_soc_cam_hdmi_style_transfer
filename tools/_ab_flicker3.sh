#!/usr/bin/env bash
# 时域抖动第三轮：① granule 强度扫描（是线性调制还是阈值悬崖）
#                  ② 均值归一换成固定常数（逐帧均值是不是那个"全局增益"）
set -u
cd "$(dirname "$0")/.."

BASE=(--ckpt runs/D_wc_g15 --input runs/VIDEO_material --limit 99 --max-side 0 --dump-panels
  --line-source none --chroma-blend 0.15 --chroma-style great_wave --luma-match
  --flat-mode none --con 1.5 --con-auto --sat 0.85 --black-lift 0.18 --black-lift-auto
  --wc-edge 0.5 --wc-paper 0.05
  --kuwahara-aniso 1 --kuwahara-sharp 3 --kuwahara-coh 0.01 --kuwahara-down 2 --kuwahara-angles 12
  --kuwahara-guide 2 --kuwahara-guide-mode step --kuwahara-guide-eps 0.2 --kuwahara-guide-width 0.6
  --sat 1.10 --wc-sat-mid 1.30 --wc-model mul
  --wc-tooth 0.15 --wc-humidity 0.16 --wc-deposit 0.25 --wc-deposit-thr 0.05)

# ① granule 强度扫描（其余固定）
for gv in 0.10 0.30 0.60; do
  python -m tools.toon "${BASE[@]}" --wc-granule $gv --out "runs/_ab_g$gv" >/dev/null 2>&1
done

# ② 归一化探针：granule 定稿值 0.30，den 用固定常数而非逐帧均值
python -m tools.toon "${BASE[@]}" --wc-granule 0.30 --wc-norm-const 0.87 \
  --out runs/_ab_normfix >/dev/null 2>&1

# 逐帧 mod 均值（看它到底抖多少）—— 打印在 stdout 里
echo "===== 逐帧 mod 均值（v1 有 6 帧就 6 行） ====="
python -m tools.toon "${BASE[@]}" --wc-granule 0.30 --wc-verbose --limit 99 \
  --out runs/_probe_norm 2>&1 | grep "纸纹.*mod 均值" | head -30

for t in g0.10 g0.30 g0.60 normfix; do
  echo "===== $t ====="
  python -m tools.flicker --content runs/VIDEO_material --stages "runs/_ab_$t" \
    --out "runs/view_big/AB_FK3/$t" 2>&1 | sed -n '/^|/p'
done
