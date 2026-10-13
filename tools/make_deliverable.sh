#!/usr/bin/env bash
# 把两种网络的**训练权重 + RTL 交接物**收进一个自包含的文件夹，再独立校验一遍。
#
#   bash tools/make_deliverable.sh
#
# 为什么是脚本不是一次性 cp：网络重导（`python -m train.deploy`）之后要能重建，
# 且**重建完必须过 `check_deploy`**——不过就不算交付。
set -euo pipefail
cd "$(dirname "$0")/.."          # -> sim/

OUT=../deliverable                # 顶层，好找好压缩
if [ -d "$OUT" ]; then rm -rf "$OUT"; fi
mkdir -p "$OUT"

# ⚠ README **不手写在包里**——脚本开头会把整个目录删掉重建，
# 手写在包里的 README 活不过第二次跑。模板放 sim/ 里，每次拷过去。
cp tools/deliverable_README.md "$OUT/README.md"

for t in D_sw1e5 D_wc_g15; do
  src="runs/final/$t"
  [ -d "$src/deploy" ] || { echo "✗ $src/deploy 不存在"; exit 1; }
  mkdir -p "$OUT/$t"
  # 训练产物：原始 ckpt（要重导/重训用）
  cp "$src/net.pt" "$OUT/$t/net.pt"
  [ -f "$src/net_folded_fp32.pt" ] && cp "$src/net_folded_fp32.pt" "$OUT/$t/net_folded_fp32.pt"
  # golden 的输入图，给 RTL 侧当 smoke test 的现成素材。
  # ⚠ 训练脚本把 input.png 留在 `runs/<tag>/`，不是 `runs/final/<tag>/`——两个地方都要找。
  for cand in "$src/input.png" "runs/$t/input.png"; do
    if [ -f "$cand" ]; then cp "$cand" "$OUT/$t/sample_input.png"; break; fi
  done
  [ -f "$OUT/$t/sample_input.png" ] || echo "  ⚠ $t 没找到 input.png，包里少了 sample_input.png"
  # **交接物本体**：整个 deploy/ 原样搬
  cp -r "$src/deploy" "$OUT/$t/deploy"
  # 层表从 spec.json 生成，**不手抄**（重导一次手抄的必然过期）
  python -m tools.spec_md "$OUT/$t/deploy/spec.json" -o "$OUT/$t/LAYERS.md"
  # 网络结构图（赛题「超轻量化网络自设计」要求提交结构图，之前只有逐层表）。
  # 同样是生成的，拓扑写死在 net_diagram.py 里，spec.json 名字对不上会直接报错。
  python -m tools.net_diagram "$OUT/$t/deploy" -o "$OUT/$t/ARCH.svg"
  # 参数量统计表（赛题「超轻量化网络自设计」要交）。对账不过直接退出，不出货
  python -m tools.param_table --tag "$t" --ckpt "$OUT/$t/net.pt" \
    --deploy "$OUT/$t/deploy" --out "$OUT/$t/PARAMS.md"
done

# 两份合成一张，赛题要的是"统计表"
python - "$OUT" <<'PY'
import io, sys
from pathlib import Path
out = Path(sys.argv[1])
hdr = ("# 参数量统计表\n\n由 `tools/param_table.py` 从 **ckpt + deploy/spec.json** 实数生成，**不手抄**。\n"
       "重建：`bash sim/tools/make_deliverable.sh`\n\n")
parts = [io.open(out / t / "PARAMS.md", encoding="utf-8").read() for t in ("D_sw1e5", "D_wc_g15")]
io.open(out / "PARAMS.md", "w", encoding="utf-8").write(hdr + "\n---\n\n".join(parts))
print("PARAMS.md 已生成（2 个网络）")
PY

# 校验器跟着走，让这个包**不依赖 sim/** 也能自验
cp tools/check_deploy.py "$OUT/check_deploy.py"

echo "=== 独立校验（不 import PyTorch，按 spec.json 解码 hex 重算） ==="
for t in D_sw1e5 D_wc_g15; do
  echo "--- $t ---"
  python "$OUT/check_deploy.py" "$OUT/$t/deploy" | tail -2
done

echo
echo "=== 包内容 ==="
du -sh "$OUT"
find "$OUT" -maxdepth 2 -not -path "*/golden/*" | sort
echo
echo "golden/ 每份文件数："
for t in D_sw1e5 D_wc_g15; do echo "  $t: $(ls "$OUT/$t/deploy/golden" | wc -l)"; done
