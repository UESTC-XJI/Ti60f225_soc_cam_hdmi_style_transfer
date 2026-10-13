# 风格迁移网络 —— RTL 交接包

两种网络的**训练权重**和**RTL 交接物**，自包含。来源 `G:\FPGAtest\sim\`，
重建命令 `bash sim/tools/make_deliverable.sh`（重建时会自动校验 + 对账，**不过就不出货**）。

```
deliverable/
├── README.md                ← 本文件（模板在 sim/tools/deliverable_README.md）
├── PARAMS.md                参数量统计表（赛题「超轻量化网络自设计」要交的）
├── check_deploy.py          独立校验器（只依赖 numpy，不 import PyTorch）
├── D_sw1e5/                 ← 风格 1：星空 / 梵高     三通道
│   ├── net.pt               训练后的浮点权重（要重导/重训用这个）
│   ├── net_folded_fp32.pt   InstanceNorm 折叠后的浮点版（RTL 对账用）
│   ├── sample_input.png     golden 用的那张输入图
│   ├── LAYERS.md            层表 + 量化 + scale（从 spec.json 生成，别手改）
│   ├── ARCH.svg             ★ 网络结构图（同上，生成不手画）
│   ├── PARAMS.md            本网络的参数量（多口径）
│   └── deploy/              ★ 交接物本体
└── D_wc_g15/                ← 风格 2：水彩              亮度域
    ├── net.pt
    ├── sample_input.png
    ├── LAYERS.md
    ├── ARCH.svg             ★ 网络结构图
    ├── PARAMS.md
    └── deploy/              ★ 交接物本体
```

### `ARCH.svg` —— 结构图，和逐层表互补

`LAYERS.md` 能查数，但**看不出拓扑**：哪几层在下采样、残差从哪接到哪、
上采样在卷积之前还是之后、哪一层的输入可能为负。这些恰恰是 RTL 最容易接错的地方。

图是**生成的**（`python -m tools.net_diagram <deploy>`），拓扑写死在生成器里，
只从 `spec.json` 取数字；层名对不上会**直接报错**，不会静默画一张跟实现脱节的图。
SVG 是纯文本，浏览器/Office 直接打开，放大不糊。

`deploy/` 里有什么：

| 文件 | 是什么 |
|---|---|
| `spec.json` | **硬件照着这个做**。层序、每层的 k/stride/cin/cout、权重与偏置在 hex 里的偏移、量化 scale |
| `weights.hex` | int8 对称量化权重（per-tensor scale） |
| `biases.hex` | int32 偏置，值 = `round(b / (activation_scale_in × weight_scale))` |
| `weights.json` | 同一份权重的可读版（调试用，硬件不用） |
| `net_deploy.pt` | 折叠+微调后的 PyTorch 模型，`--deployed` 之类的对账用 |
| `manifest.json` | **每个文件的 sha256**。传输损坏先在这里现形，别去查 RTL |
| `golden/` | **逐层整数基准**：12 层 × (`_in.hex` 输入 / `_acc.hex` 累加器) + `input.hex` + `golden.json` |
| `golden/cases/` | **四组定向向量**：`zeros` / `ones` / `checker` / `random`，每份结构与 `golden/` 相同 |

⚠ `weights.hex` 和 `biases.hex` 是**两个文件**（int8 / int32 位宽不同，混一起没法
`$readmemh`），各自有独立偏移。层记录里的 `weight_offset` / `bias_offset` 是
**各自文件内**的偏移。

### `manifest.json` —— 先验它，再看 golden

```
python check_deploy.py D_sw1e5/deploy     # 先验 sha256，再逐层比对
```

**为什么要有**：交接物是跨机器/跨介质传的（U 盘、网盘、提交系统）。`weights.hex`
差一个字节，合出来的就是**另一个网络**，而逐层 golden 比对**不会告诉你"传坏了"**
——它只会报某几层对不上，让人去查 RTL，方向从第一步就错了。
先过哈希，能把「传输出错」和「实现出错」分开。

⚠ 这是**完整性**校验，不是**真实性**校验：能改文件的人也能改清单。防传输损坏，不防篡改。

### `golden/cases/` —— 为什么要四组，不是一张图

只有一张内容图的话，RTL 那边"12/12 通过"**也可能什么都没证明**——
所有累加器都落在中间值区间，**饱和路径、零值通路、符号翻转一次都没走到**。
WBS 3.6 要的正是这四类：

| 向量 | 打什么 |
|---|---|
| `zeros` | 偏置通路。累加器应恒等于量化偏置，接错线立刻现形 |
| `ones` | 上界饱和。踩到 qrange 上沿，考验 `clamp` 而不只是 `round` |
| `checker` | 空间极值 + 符号翻转。相邻像素 0/1 交替，最能把有符号层的负数分支逼出来 |
| `random` | 通用性。固定种子（1234），可复现 |

实测各组的**负累加器占比 31%~47%**（`export` 时打印），符号路径确实被走到。

⚠ 四组向量各 64×64，**golden 从 1.15MB 涨到 6.2MB**（整包 13MB）。
要压小就重导时用 `--golden-side 32`，覆盖力不变（逐元素比对与尺寸无关）。

---

## 两个网络

| | `D_sw1e5` | `D_wc_g15` |
|---|---|---|
| 风格 | 星空 / 梵高（`starry_night`） | 水彩（萨金特参考图 + 边缘保持微调） |
| 结构 | `改D: 1/8ch 3res 3x3` | `改D-Y: 1/8ch 3res 3x3 亮度域` |
| 输入通道 | **3**（RGB） | **1**（只有 Y） |
| 输出通道 | **3** | **1**（只有 Y） |
| 最宽通道数 | 16 | 16 |
| 层数 | 12 | 12 |
| 部署权重（INT8） | 16,920 B | 16,776 B |

**两个网络只差 `enc1` 和 `out` 的通道数**，中间 10 层（`enc2` / `enc3` /
`res.0~2` 各两层 / `dec1` / `dec2`）**完全相同**。
⇒ 硬件可以只做**一套**数据通路，靠配置切换首尾两层的通道数。

参数量的**多口径**对比见 `PARAMS.md`。⚠ 赛题只写「参数量小于 500KB」，
没说精度、也没说算不算 norm —— **报的时候要说清用的是哪个口径**。

### 亮度域网络（`D_wc_g15`）要多做两件事

它只吃 Y、只吐 Y。**色度自己接回去**：

```
输入：   Y = 0.299·R + 0.587·G + 0.114·B     ← BT.601，和 MIPI/HDMI 通路一致
输出：   最终_i = 内容_i × (Y_out / Y_in)      ← 逐像素按比例缩放，保 Y 不变
```

（这就是 `train/data.py::merge_luma` 做的。亮度域网络训练时**不喂色度**，
所以硬件上色度可以走旁路直通。`tools/toon.py` 里的 `--chroma-blend` 配色旋钮
是**后处理**的事，不影响网络。）

### ⚠ 输入尺寸

- **边长必须是 4 的倍数**。两级 stride-2 下采样被两级 ×2 上采样补回，`pad → conv`
  保尺寸 ⇒ 任何 4 的倍数都守恒（8×8 都能往返）。
- **720p 是 1280×720 —— 两个数都是 4 的倍数，直接喂。**
- `golden/` 用的是 **64×64**（为了把交接物压到 MB 级）。
  **校验效力与尺寸无关**（逐元素比对）；实测 64 下**符号层负累加器占 21~48%**，
  说明负数分支没被绕开。
- ⚠ 判据是**累加器不能是常数**，不是"尺寸要够大"——纯色输入会触发这个检查。

---

## 怎么验

```bash
python check_deploy.py D_sw1e5/deploy
python check_deploy.py D_wc_g15/deploy
```

**不 import PyTorch**，纯按 `spec.json` 解码 hex 重算整数卷积逐元素比对
——**这正是 RTL testbench 要做的事**。当前两份都是 **5 组向量 × 12 层全通过**，
且 manifest 的 135 个文件 sha256 全对。

**它验什么**：先验 `manifest.json` 的 sha256（文件没传坏），
再验每层 `acc = conv(q_in, q_w) + round(b / (s_a · s_w))` 与 golden 逐元素相等。
即 hex 编码、偏移、`cout×cin×k×k` 行主序、逐通道 scale、偏置量化刻度。

**它不验什么**：**层与层之间的接线**（残差走哪条路、`_out` 的再量化接哪个 scale）。
`q_in` 是真实前向里流进来的张量，脚本把它当**已知输入**用。
⇒ **它证明"给定输入，硬件算得对"，不证明"图的接线对"。** 后者要靠 RTL 侧的整图仿真。

---

## 硬件设计规格在哪

这个包只覆盖**网络**。其余部分在 `sim/FPGA-IMPL.md`：

| 要的东西 | 看哪 |
|---|---|
| 算力预算、DSP 例化（`EFX_DSP48` **必须显式例化 DUAL 模式**，自动推断拿不到双 MAC） | `FPGA-IMPL.md` §2.4 |
| 片上存储预算（BRAM 分档、CSI-2 FIFO 深度） | `FPGA-IMPL.md` §3.0 / §3.3 |
| **后处理链的算子、顺序与存储开销** | `FPGA-IMPL.md` §3.7-bis / §3.7-ter，成本用 `sim/tools/pp_cost.py` 复现 |
| 效果原型的完整配方与理由 | `sim/runs/final/README.md` §3 |

> ⚠ **500KB 不是卡脖子的那个指标。** 720p 下网络占 **184.2 KB** 片上存储
> （行缓冲 137.5 + 残差延迟 30.0 + 权重 16.7），而 1 核 Sapphire + 小 CSI-2 FIFO
> 的可用量是 **176~215 KB**——**只有一种配置成立**（1核 + Sapphire 43 块 +
> CSI-2 FIFO 17 块 + 残差/行缓冲共享，余 12.4 KB）。详见 `FPGA-IMPL.md` §3.3/§3.7-bis。

---

## ⚠ 交付前该知道的

- **这是 INT8 部署版，不是训练原型**。原型里 InstanceNorm 是活的，部署时被折叠成
  定值——**折叠会损失一部分逐帧稳定性**（`sim/tools/temporal_check.py` 量过）。
- 后处理链**还没有 RTL**，目前只有 Python 原型和存储预算。
- `D_ukiyoe`（三通道浮世绘）**已被 `D_wc_g15` 取代**，不在这个包里。
  旧版的问题：颜色被整体染成青蓝、与输入颜色无关。
- **赛题要求的「与简化版 CycleGAN 比 PSNR/SSIM 与推理延迟」还没做。**
  目前只有网络自身的 PSNR/SSIM，没有对照标准网络。这是这条高阶分的必要条件。
