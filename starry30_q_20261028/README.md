> ⚠ **本包的实际状态与最终产物/复现步骤见 [README_PACKAGE.md](README_PACKAGE.md)**（下面的数字是 zip2 基线口径）。

# Ti60F225 实时 AI 风格化视频（SC431HAI → CNN → HDMI）

易灵思 Titanium **Ti60F225** 上的端到端实时风格迁移：MIPI 摄像头 RAW → debayer/ISP → 640×480 风格网络（行缓冲全流水）→ 720p60 HDMI 输出。RISC-V 软核跑 3A 与任务调度。

**当前状态：31 fps 稳定运行，逻辑占用 98.97%，参数量仅为赛题上限的 2.9%。**

---

## 一 实板实测

| 指标 | 数值 | 口径 |
|---|---|---|
| **风格化帧率** | **31 fps** | 640×480，端到端（采集→推理→显示） |
| **推理耗时** | **MS 26–27 ms** | 算力 18 + 读等待 8 |
| 传感器帧率 | VTS 1457（1080p 原生） | `raw_frames` 实测 |
| **丢帧** | **DROP 0 / UF 0 / FAULT 0** | 连续运行，`PF == PFC` 无泄漏 |
| 逻辑 | **XLR 60,171 / 60,800（98.97%）** | PnR 后 |
| RAM / DSP | **202 / 256**、**147 / 160** | PnR 后 |
| 时序 | vid_clk_dvi2 **+0.441 ns**、core_clk +2.032、hdmi_tx_slow +5.787 | I3 时序模型 |
| 网络 | 12 层 3×3 INT8，**5,400 个参数** | 部署 blob 14,448 B |
| 显示 | 720p60 | 左原画 / 右风格，按键可切全屏 |
| **多风格切换** | **4 套**，SWT **43–90 ms** | < 100 ms 达标，切换时 DROP 不增 |

### 与标准网络的对比

| | 本设计（Ti60 FPGA） | 标准 CycleGAN（RTX 4060 Laptop） |
|---|---|---|
| 延迟 @320×240 | **26.5 ms** | 27.34 ms |
| 参数量 | **5,400** | 11,378,179（**2,107 倍**） |

同分辨率下延迟持平，参数量少三个数量级。

---

## 二 架构

### 数据通路

```
SC431HAI (1920×1080 RAW10, 4-lane MIPI)
   ↓ 内置 D-PHY + CSI-2 RX
debayer (BGGR) + ISP
   ↓ 中心裁 1280×960 → 2×2 均值降采样
640×480 {B,G,R,X} → DDR 捕获 slot（6 个三态轮转）
   ↓
rowpipe 加速器（12 层，层内行流水，单实例复用）
   ↓
320×240 结果帧 → DDR（显示端 2× 最近邻放大到 640×480）
   ↓
720p60 HDMI（左原画 / 右风格）
```

### 网络（12 层 dense 3×3，全 INT8）

| 层 | ci→cout | 输出 | 操作 | 感受野(输入 px) |
|---|---|---|---|---|
| L0 | 3→4 | 640×480 | 3×3 | 3 |
| L1 | 4→8 | 320×240 | 3×3 stride2 | 5 |
| L2 | 8→8 | 160×120 | 3×3 stride2 | 9 |
| L3–L9 | 8→8 | 160×120 | 3×3（L4/L6/L8 带残差） | 17–65 |
| L10 | 8→4 | 320×240 | 3×3 + up2 | 69 |
| L11 | 4→3 | 320×240 | 3×3 | **73** |

**感受野 73 输入像素 = 画面宽的 11.4%。**

### 关键设计决策

| 决策 | 原因 |
|---|---|
| **单实例层复用** | 12 层共用 1 个 `rowpipe_layer`（描述符逐层重配）。若每层独立实例需 325k XLR ≈ 器件容量的 5 倍 |
| **CI/CO = 8** | 从 16 降到 8 省下 XLR 491 / RAM 42 块，是后续所有优化的面积前提 |
| **TAIL_LOWRES=1** | L9/L10/L11 半分辨率。**这不只是性能优化——全分辨率尾层实测 XLR 60,253（99.10%）布线失败** |
| **显示端 2× 放大** | 结果帧 320×240，把放大搬到显示端。写通道做复制既慢又有 bug（奇数行曾出 384~512 个垃圾像素） |

---

## 三 优化历程（17.9 → 31 fps）

| 阶段 | 动作 | MS | 帧率 |
|---|---|---|---|
| 起点 | — | 50 ms | 17.9 fps |
| 总线优化 | posted-B + 读优先级 | 39 ms | **17.9 fps（没变）** |
| **诊断** | 读 `raw_frames` 寄存器 | — | **发现瓶颈在传感器** |
| 网络侧 | CI/CO=8 + TAIL + A-1/2/4 | **26 ms** | 23 fps |
| 传感器侧 | VTS 2500 → 1457 | 27 ms | **31 fps** |

**最重要的教训**：优化算力时帧率纹丝不动，读了 `raw_frames` 才发现传感器 VTS 被钉在 2500 行（57 ms 周期）。

> **帧率 = 1 / max(传感器帧周期, 推理时间)** —— 只改一侧无效。

逐项贡献：A-2（跳过 S_DRAIN）−3.76 ms、A-1（L9 半分辨率）−2.24 ms、A-4（显示端放大）−4 ms。

---

## 四 仓库结构

```
rtl/
  accel_rowpipe/     12 层推理引擎（layer / engine / ddr_banks / frame_driver）
  style/             网络描述符 / 帧管理 / 显示 / APB 桥
  soc_integration/   SoC 顶层、APB 寄存器、视频前级
  cam*/ debayer/ isp/ csi_rx_controller.sv …   平台与视频前级

software/
  firmware/          RISC-V 固件：启动 / 3A（含 AGC）/ 风格驱动 / 权重

tools/
  build_check.py     构建裁决（阶段 + slack + 面积），退出码可直接接 CI
  smoke_test.py      烧录后三步冒烟（CPU / CORE_ID / DDR 读回）
  flash_bit.py       位流烧录（自动发现 FTDI）
  style_metrics.py   PSNR / SSIM（纯 numpy）
  style_loss_metric.py  与训练同款的 VGG Gram 风格损失
  build_firmware.sh  固件构建（weights 变体 + XOR 打印）

reports/             分析报告（见 §六）
tests/               仿真 testbench
weights/             4 套 DC 固化权重（每套 14,448 B blob）
```

---

## 五 构建与烧录

### 位流

```bash
cmd /c _b.bat                                  # Efinity 全流程，约 15 分钟
python tools/build_check.py                    # 裁决：USABLE / TIMING_FAIL / ROUTE_FAIL
```

⚠ **`pnr PASS` 不等于可用**——必须看 `build_check.py` 的裁决。
面积在 99% 附近时**布线成功与否是概率性的**（99.00% 失败 / 98.96% 通过均实测过）。

### 固件

```bash
bash tools/build_firmware.sh weights/starry_old_signed_dc/rowpipe_weights.h
# 输出：software/firmware/build/soc_video_app.elf / .bin
```

### 上板（**每次上电都要做第一步**）

```bash
python tools/flash_bit.py                      # 1. 烧位流
# 2. OpenOCD → reset halt → load_image {elf} → reg pc 0x1000 → resume
python tools/smoke_test.py                     # 3. 冒烟测试（必做）
```

⚠ **FPGA 重新上电会从 SPI flash 加载旧位流**（JTAG 配置是易失的）。
**只看 UART 不够**——已验证过"构建全绿 + 时序全正 + 面积更低，但固件起不来"的事故，只有冒烟测试能抓到。

### 冒烟测试三条

```
① resume 后 2 秒 reg pc != 0            CPU 在跑
② mdw 0xf8100000 == 0x4f534431          video 核
   mdw 0xf8100200 == 0x3154534e          style 核
③ mdw 0x1000 == ELF 首字                 DDR 读写正确（最关键，能暴露 DDR 裕量问题）
```

### 多风格切换

串口 115200：发 `s` 列清单，发 `1`–`4` 切换。

```
STYLE BANKS 1:starry_old* 2:starry_v7 3:starry_v8 4:red_v3_dc
STYLE SW 2 starry_v7 ok wait 17274us copy 1041us
```

机制：先清 `stream_enable` 让引擎跑完当前帧后稳定停在 idle，再拷贝 14,448 B 权重并做 XOR 自检
（失败自动回滚），最后恢复。**不能用 `nn_ready` 轮询**——`job_done` 后 `pending` 只清 1 个时钟
（10 ns），CPU 和 PLIC 中断都赶不上，会与下一帧重叠产生混风格帧。

---

## 六 重要文档

| 报告 | 内容 |
|---|---|
| `reports/ARCHITECTURE_FREEZE_2026-10-28.md` | **架构冻结基线**：上板流程、三个失败模式、明确不做的七件事、三级回退 |
| `reports/FOR_MODEL_BRUSHSTROKE.md` | **笔触问题根因**（给模型侧）：感受野 73 px vs 参考笔触 25~50% 画宽 |
| `reports/BRUSHSTROKE_QUALITY_ANALYSIS.md` | 画质完整分析：尺度谱、时间稳定性、风格损失 |
| `reports/DILATION_DESIGN_SPEC.md` | dilation 支持设计（**只设计未实现**，等模型侧正式权重） |
| `reports/C3_ULTRALIGHT_NETWORK.md` | 赛题高阶 C3：结构图 + 参数量表 + 对比 |
| `reports/C3_PSNR_SSIM.md` | PSNR/SSIM 与标准网络延迟对比 |
| `reports/A5_UPSCALER_DESIGN.md` | 显示端放大器论证（结论：不值得改） |
| `reports/DEMO_PLAN.md` | 演示场景 + 答辩要点 + 分镜 |
| `reports/line_by_line/` | 逐行代码审计 |

---

## 七 已知限制（诚实清单）

| 限制 | 量化 | 状态 |
|---|---|---|
| **笔触尺度偏细** | 网络输出 ≥25% 画宽能量 **12.6%**，参考图 **88.5%** | 根因是感受野 73 px；模型侧 dilation 离线验证已通过（dil3: 89.7%），等正式权重 |
| **读等待 8 ms** | 其中约 6.5–7 ms 是被掩盖的延迟、真停顿仅 1–1.5 ms | 未解决 |
| **面积余量仅 629 块（1.03%）** | 任何改动都可能布不通 | 已冻结架构 |
| 切换时采集暂停 ≤50 ms | 最多跳过 1 个源帧（不产生损坏帧、不丢队列帧） | C1 的固有取舍 |
| 显示端 WB 增益全局一组 | 换风格会有色偏变化 | 预期行为 |
| 功耗 | **未实测** | 不给数字 |

### 明确不做（都已实测验证不可行）

| 方向 | 原因 |
|---|---|
| 撤面积腾地方（如撤 profiler） | 实测 **−418 XLR 的纯删除就能让固件起不来** |
| TAIL_LOWRES=0（L11 全分辨率） | XLR 60,253（99.10%）**布线失败** |
| 层融合（L3~L9） | 收益仅 ~1 ms，面积缺口 4 倍 |
| 1280×720 处理 | 算力 47.8 ms vs 预算 33.3 ms，三条独立的墙（算力/时钟/DSP） |
| 显示端换插值 | 特征尺度只能从 2 px 挪到 3 px（目标 160~320 px） |
| 压低 VTS 提帧率 | 会丢帧，且曝光上限等比下降 |

---

## 八 测量两个必须知道的坑（都踩过）

1. **DDR 是偏移二进制，必须 `raw ^ 0x80`**
   网络输出有符号 `q ∈ [-128,127]`，存成字节时 `+128`（≡ `XOR 0x80`）。
   不做这个转换会把尺度谱从 **12.6% 虚报成 38.7%**——因为 `XOR 0x80` 对接近 0/255 的值
   翻转 MSB，引入大量假高频边缘。

2. **参照图必须过同一工具做交叉校验**
   `starry_night.jpg` 的 ≥25% 画宽应 ≈ **88.5%**（误差 <1 点）。算不出来就说明口径错了。

```python
assert 像素第4字节 == 0              # X 填充必须为 0
img = raw[:, :, :3] ^ 0x80           # 必须做偏移二进制转换
# 参照图 >=25% 画宽 应 ≈ 88.5%
```

**同理**：任何"基线"也要先验证有效性。一帧坏 dump 曾让风格损失改善倍数错了 4 倍（8.0× → 2.1×）。

---

## 九 调试遥测

UART 115200 每帧输出：

```
MONET CAP 31 NN 31 DISP 0 DROP 0 MS 27 ERR 0
3A state 1 expL 1114 expH 1 vts 1457 mean 112 hot 284 goal 112 hold 1 R 400 B 414 AE 31 AWB 0 agc 4 agcN 10
DDR100M T ... RPMS 8 CPMS 18 PF 14197 PFC 14197 WW 9
VIDEO UF 0 DUF 0 DDROP 0 FAULT 0 CSI 0 DME 0 IERR 0 AXI 0 SW 2 SWT 90 SWE 0
```

单位陷阱：**`expL` 是行、`expH` 是半行奇偶、`vts` 是行**。曝光上限 = `2×VTS − 11`（半行）。

关键寄存器（style APB `0xf8100200`）：

| 偏移 | 内容 |
|---|---|
| `0x00` | CORE_ID（应 `0x3154534e`） |
| `0x04` | stream_enable（bit4 采集+任务，bit0 手动起帧） |
| `0x38` / `0x3c` / `0x40` | captured / dropped / inferred |
| `0x150`（video，`0xf8100150`） | raw_frames —— **传感器真实帧率，诊断瓶颈必看** |

---

## 十 当前状态与待办

| 项 | 状态 |
|---|---|
| 赛题基础要求 | ✅ **11 条全满足**（FPS 要求 30，实测 31） |
| 高阶 C1 多风格切换 | ✅ **已实现并上板验证**（4 套、DROP 0、SWT < 100 ms） |
| 高阶 C3 超轻量网络 | ✅ 材料已交付（参数量 2.9% 上限，延迟与 4060 持平） |
| 高阶 C2 / C4 | ❌ 不做（技术不可行 / 投入产出比低） |
| **待模型侧** | dilation 离线验证已完成（dil3: 89.7% ≥ 目标 70%），等正式权重导出后上板验证 |
