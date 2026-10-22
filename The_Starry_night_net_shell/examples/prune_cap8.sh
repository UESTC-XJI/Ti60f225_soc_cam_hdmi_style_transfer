#!/usr/bin/env bash
# 训练 → 通道前缀剪枝 → 微调，一条龙。
# 用法：在仓库根目录执行 bash examples/prune_cap8.sh
set -euo pipefail

STYLE="${STYLE:-starry_night}"
BASE_TAG="${BASE_TAG:-baseline}"
PRUNE_TAG="${PRUNE_TAG:-pruned}"
FT_TAG="${FT_TAG:-pruned_ft}"

if [ ! -f "runs/${BASE_TAG}/net.pt" ]; then
    echo "[1/3] 训练基线 → runs/${BASE_TAG}"
    python -m train.train --net "改D: 1/8ch 3res 3x3" --style "${STYLE}" \
        --steps 4000 --tag "${BASE_TAG}"
else
    echo "[1/3] 已有 runs/${BASE_TAG}/net.pt，跳过训练"
fi

echo "[2/3] 通道前缀剪枝 → runs/${PRUNE_TAG}"
python -m train.prune --ckpt "runs/${BASE_TAG}/net.pt" \
    --net "改D: cap8 3res 3x3" --out "runs/${PRUNE_TAG}" --overwrite

echo "[3/3] 微调 → runs/${FT_TAG}"
python -m train.train --net "改D: cap8 3res 3x3" --init "runs/${PRUNE_TAG}" \
    --style "${STYLE}" --steps 2000 --lr 5e-4 --tag "${FT_TAG}"

echo "完成：runs/${FT_TAG}/net.pt"
