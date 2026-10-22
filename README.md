# 超轻量快速风格迁移：通道剪枝 + 微调

面向 FPGA 部署的 Fast Neural Style 网络。训练、**通道前缀剪枝**、剪枝后微调、出图，全部在 `train/` 里，纯 PyTorch，无私有依赖。

- 网络：Johnson et al. 的 encoder–residual–decoder，反射填充卷积 + InstanceNorm(affine)
- 训练：VGG16 感知损失（content + Gram style + TV）
- 剪枝：结构化通道剪枝（保留通道前缀），剪完热启动微调
- 目标：在 640×480 上实时，权重压到几 KB～几十 KB

## 快速开始

```bash
python -m venv .venv
# Windows: .venv\Scripts\activate    Linux/macOS: source .venv/bin/activate
pip install -r requirements.txt

# 1) 下载数据（COCO val2017 前 N 张 + Wikimedia 公版风格图）
python -m train.fetch_data --content 800 --styles 3

# 2) 训练基线（约 17.3K 参数）
python -m train.train --net "改D: 1/8ch 3res 3x3" --style starry_night \
    --steps 4000 --tag baseline

# 3) 通道前缀剪枝 → cap8（中间通道 16→8，5.6K 参数）
python -m train.prune --ckpt runs/baseline/net.pt \
    --net "改D: cap8 3res 3x3" --out runs/pruned

# 4) 微调（必须做，否则画质明显下降）
python -m train.train --net "改D: cap8 3res 3x3" --init runs/pruned \
    --style starry_night --steps 2000 --lr 5e-4 --tag pruned_ft

# 5) 出图
python -m train.stylize --ckpt runs/pruned_ft --input data/content --limit 5 --max-side 640
```

第一次训练会自动下载 VGG16 预训练权重（约 528 MB）。

## 剪枝做了什么

只剪**卷积输出通道**，并且每个卷积**保留前 N 个通道**：

```
W' = W[:co_new, :ci_new, :, :]
```

不按权重的重要性重排通道。这是一个刻意偏袒硬件的选择：小网络的每一行仍是原权重的一段前缀，部署时权重可以按固定行宽连续摆放，不需要 gather/重排；代价是被剪掉的通道不一定最不重要，所以**必须微调**。

模型族（`train/model.py`）的通道数按 `mult` / `cap` 单调缩放，因此小网络的每个通道都在大网络里存在且编号相同——这是前缀剪枝成立的前提。脚本会逐层核对形状，任何不兼容都直接报错，不会静默截断。

| 网络 | 通道 (enc1/enc2/enc3) | 参数量（含 IN affine） | 说明 |
|---|---|---:|---|
| `改D: 1/8ch 3res 3x3` | 4 / 8 / 16 | 17,331 | 基线；去掉 IN affine 为 17,059 |
| `改D: cap8 3res 3x3` | 4 / 8 / 8 | 5,643 | 中间层 16→8，画质几乎不掉 |
| `改D: 1/16ch 3res 3x3` | 2 / 4 / 8 | 4,491 | 极窄；非重训剪枝画质明显变差，仅作下限 |

实测（同一张图、同一风格）：cap8 剪枝 + 2K 步微调后与原模型肉眼几乎一致；按“输出 vs 输入内容图”计的 PSNR/SSIM 为 12.43 dB / 0.2836（原模型 11.88 dB / 0.2541）。这两个指标衡量的是内容保留，不是“像不像画”，需配合样张一起看。

## 命令与参数

### `train.train` — 训练 / 微调

```bash
python -m train.train --net "改D: cap8 3res 3x3" --style starry_night --steps 3000
```

| 参数 | 默认 | 含义 |
|---|---|---|
| `--net` | `改D: 1/8ch 3res 3x3` | 结构，可选值见 `train/model.py::BUILDERS` |
| `--style` | `starry_night` | 短名 / 文件路径 / 目录（多图时随机采样） |
| `--steps` | 3000 | 训练步数 |
| `--lr` | 1e-3 | 学习率（微调建议 5e-4） |
| `--init` | 无 | 热启动：从 `runs/<tag>` 或 `net.pt` 载入权重 |
| `--tag` | 自动 | 输出到 `runs/<tag>/` |
| `--calibrate` | 关 | 只跑一步，打印三项损失的原始量级 |

损失权重 `--content-weight` / `--style-weight` / `--tv-weight` 默认 `1 / 1e5 / 1e-4`。不确定量级时先跑 `--calibrate`。

### `train.prune` — 通道前缀剪枝

```bash
python -m train.prune --ckpt runs/baseline/net.pt \
    --net "改D: cap8 3res 3x3" --out runs/pruned
```

| 参数 | 含义 |
|---|---|
| `--ckpt` | 源 ckpt 文件或目录（目录下取 `net.pt`） |
| `--net` | 目标结构；通道数必须 ≤ 源 |
| `--out` | 输出目录，写 `<out>/net.pt` |
| `--overwrite` | 允许覆盖已有输出（默认拒绝） |

脚本会打印每一层的形状变化，并跑一次前向自检（NaN/Inf）。

### `train.stylize` — 出图

```bash
python -m train.stylize --ckpt runs/pruned_ft --input data/content --limit 5 --max-side 640
```

输出写到 `runs/<tag>/out/`，同时打印 PSNR/SSIM。

### `train.fetch_data` — 下载数据

```bash
python -m train.fetch_data --content 800 --styles 3
```

内容图来自 COCO val2017（Fast Neural Style 论文同款数据）；风格图从 Wikimedia Commons 取公版名画（梵高《星月夜》、葛饰北斋《神奈川冲浪里》等）。

## 目录结构

```
train/
  model.py      FNSNet 及各候选结构（BUILDERS）
  prune.py      通道前缀剪枝
  train.py      训练 / 微调主程序
  stylize.py    推理出图 + PSNR/SSIM
  data.py       内容图随机裁剪、风格图预处理、亮度/色度工具
  vgg.py        VGG16 感知损失
  quant.py      训练期输出量化（STE），剪枝流程不需要
  metrics.py    平坦度/噪声等训练监控指标
  fetch_data.py 下载 COCO + 风格图
examples/
  prune_cap8.sh 一页纸跑完“训练 → 剪枝 → 微调”
```

运行产物（`runs/`、`data/`、`*.pt`）已在 `.gitignore` 中忽略。

## 说明

- 网络名里的“改D / cap8”是项目内的实验代号，保留原名是为了让现有 ckpt 直接可用；结构本身在 `train/model.py` 里有完整定义。
- 代码注释保留了项目当时的实验记录风格；其中提到的 `stnet/`（硬件成本模型）和 `tools/`（部署后处理）**不包含在本仓库**，不影响训练与剪枝流程。
- 训练与推理的输入尺寸不必相同：网络全卷积，训练用 256×256 随机裁剪，推理可直接喂 640×480（InstanceNorm 统计量会随尺寸变化，但风格表现一致）。
- 剪枝只处理该模型族的前缀结构；对任意 CNN 做通用剪枝需要额外的通道重要性评估与重排，不在本脚本范围内。

## 参考

- Johnson, Alahi, Fei-Fei. *Perceptual Losses for Real-Time Style Transfer and Super-Resolution*. ECCV 2016.
- pytorch/examples `fast_neural_style`
