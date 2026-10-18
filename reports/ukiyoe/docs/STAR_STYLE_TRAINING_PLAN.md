# 星空风格模型训练计划

> 目标：在现有 Ti60F225 风格迁移 Demo 的硬件框架内，把风格目标从 Monet 换成**星空**。
> 本文所有约束均来自对当前仓库代码的实测核查，非推测。

---

## 1. 当前管线的实测事实

### 1.1 网络结构（`ml/style_transfer/model.py`）

```
Student (channels=24, blocks=4)
  enc:  Conv3x3 s2 (3→8) → DWConv3x3 s2 (8→8) → Conv1x1 (8→24)
  res:  4 个 block，每块 [DWConv3x3, Conv1x1, DWConv3x3, Conv1x1] + 残差
  dec:  DWConv3x3 (24→24) → Conv1x1 (24→8) → [up 2x]
        DWConv3x3 (8→8)  → Conv1x1 (8→3)  → [up 2x]
```

**关键实测数据**：

| 项 | 值 | 来源 |
|---|---|---|
| 总层数 | 23 | `rtl/style/model/graph.json` |
| 参数量 | 8,251 | `docs/STYLE_DEMO_IMPLEMENTATION.md` |
| 模型载荷 | 11,056 B | 同上 |
| 系数镜像 | 24,576 B | `rtl/style/model/coeff.bin` |
| 训练输入尺寸 | **256×256** | `train.py:32` `image_tensor(size=256)` |
| 训练内部分辨率 | 64×64 | 256 ÷ 2 ÷ 2 |
| **推理输入尺寸** | **640×480** | 板上实测 |
| **推理内部分辨率** | **160×120** | 640 ÷ 2 ÷ 2 |

### 1.2 硬件资源余量（**这是最大约束**）

| 资源 | 使用 | 容量 | 占用率 | 余量 |
|---|---|---|---|---|
| XLR（逻辑单元） | 57,870 | 60,800 | **95.2%** | 2,930 |
| RAM | 256 | 256 | **100%** | **0** |
| DSP | 140 | 160 | 87.5% | 20 |

来源：`reports/style_demo/release_display_deadline/manifest.json`

### 1.3 权重存放与更新路径（**两个位置，必须同步**）

```
① FPGA 初始化 ROM
   rtl/style/model/coeff.hex   →  $readmemh 编译进 bitstream
   生成器：ml/style_transfer/export.py

② CPU 固件（开机经 APB 下载，覆盖 ROM）
   software/firmware/style_weights.h  →  编译进 ELF
   来源：tools/prepare_style_firmware.py 直接复制 ① 的产物
   下载：software/firmware/style_driver.c 逐字写 APB
```

**重要**：`prepare_style_firmware.py` 只是把 `rtl/style/model/style_weights.h` **原样复制**到固件目录。所以单一数据源是 `export.py` 的输出。

### 1.4 完整工具链命令（`ml/style_transfer/README.md` 实测记录）

```powershell
# 数据准备
python ml/style_transfer/prepare.py --dataset ../archive --out reports/style_demo/data_v2

# 教师训练
python ml/style_transfer/train.py --manifest reports/style_demo/data_v2/manifest.json `
    --out reports/style_demo/teacher_v2 --kind teacher --steps 2500 --batch 6 --validate-every 250

# 学生训练（含 QAT）
python ml/style_transfer/train.py --manifest reports/style_demo/data_v2/manifest.json `
    --out reports/style_demo/student --kind student `
    --teacher reports/style_demo/teacher_v2/step_002500.pt `
    --steps 8000 --batch 12 --qat-after 5500 --validate-every 500

# 激活值标定（QAT 量化范围）
python ml/style_transfer/calibrate.py --checkpoint <ckpt> --manifest <manifest> --out <out>

# 导出 → 生成硬件 ROM
python ml/style_transfer/export.py --checkpoint ml/style_transfer/artifacts/student_qat.pt --out reports/style_demo/export_reproduced
python ml/style_transfer/program.py --model reports/style_demo/export_reproduced --out rtl/style/model

# 固件与比特流
python tools/prepare_style_firmware.py
python tools/build_firmware.py
```

### 1.5 训练超参数（`train.py` 默认值）

| 参数 | 默认 | 说明 |
|---|---|---|
| `--content-weight` | 1 | VGG relu3_3 内容损失 |
| `--style-weight` | **1500** | 4 层 Gram 风格损失 |
| `--distill-weight` | 5 | 相对教师的 L1 |
| TV | 0.03（硬编码） | 平滑 |
| `--lr` | 1e-3 | 线性衰减到 10% |
| 教师损失 | `content + 1500*style + .03*tv` | 无 distill |

**教师用 InstanceNorm**（可任意分辨率），**学生用 BatchNorm**（训练时固定 256×256）。

---

## 2. 星空风格的两个核心技术难点

### 2.1 难点一：星点会被 4× 下采样摧毁

**这是本计划最需要正视的问题。**

网络实际只在 **160×120** 分辨率运算（`enc` 两次 stride=2）。而星空的核心视觉特征是：

- 星点是 **1–2 像素**的高频亮点
- 密集星场是**小尺度**结构

经过 640→320→160 的两次降采样，**单个星点会衰减到不足一个像素**，能量几乎完全丢失。`dec` 的 nearest 上采样**只能放大块，不能恢复已丢失的高频**。

**结论：直接用现有架构训练星空，结果很可能是"糊掉的星云色块"，而不是"星点"**。

### 2.2 难点二：风格损失偏向纹理统计，弱化点状高光

`gram()` 计算的是通道间相关矩阵，**捕捉的是纹理的统计分布**。星点属于稀疏、极端的亮度分布，在 Gram 统计中贡献很小。相比之下，画作的笔触纹理更容易被 Gram 捕捉。

**这意味着**：即使星点侥幸存活到 160×120，风格损失也不会特别"奖励"它们。

### 2.3 参照：当前 Monet 效果的实际测量

我在板上实测了当前 Monet 输出（用于建立基线）：

| 指标 | 原图 | Monet 输出 | 变化 |
|---|---|---|---|
| 亮度标准差 | 63.6 | 51.2 | **−19.5%**（对比压缩） |
| 饱和度 | 0.328 | 0.310 | ×0.944 |
| 梯度能量 | (1.08, 1.45) | (1.35, 1.60) | +25% / +10% |
| 通道相关 | — | 0.976 / 0.983 / 0.995 | 结构保留 |

**当前是"温和的色调/纹理简化"**（与文档自述一致）。星空若要出彩，需要更激进的效果。

---

## 3. 星空 Data 集的构建

### 3.1 目录结构（`prepare.py` 硬性要求）

```
<dataset>/
  trainA/   testA/     ← 风格图（星空）
  trainB/   testB/     ← 内容图（普通照片）
```

`prepare.py` 用 dHash ≤4 连通分量分组，**自动保留原始 test 分组**，并按 10% 划出 validation。

### 3.2 星空风格图（A 域）建议

| 来源 | 说明 | 许可注意 |
|---|---|---|
| **ESO / NASA 天文图库** | 真实星空、银河、星云，高分辨率 | 多数 CC BY，需署名 |
| **Hubble / JWST 公开图** | 星云纹理丰富 | 公有领域 |
| **长曝光星空摄影** | 星轨、银河拱桥 | 需查授权 |
| **数字绘画星空** | 风格化更强（推荐混合） | 需查授权 |

**建议 100–200 张**，混合三类：纯星场 / 星云 / 星空+地景。

### 3.3 内容图（B 域）

**关键**：内容图应与**实际使用场景**匹配。板上跑的是相机实时视频（室内/室外日常场景），所以 B 域应该用**日常照片**，而不是风景大片。

建议：沿用原来的照片集（如果还保留），或收集 200–400 张日常场景。

### 3.4 风格参考选择（`style_refs.json`）

`prepare.py:50-52` 会**自动**从 trainA 中均匀抽 8 张作为 Gram 目标：

```python
paintings=[r['path'] for r in records if r['domain']=='A' and r['split']=='train']
styles=[paintings[i*(len(paintings)-1)//7] for i in range(8)]
```

**但这 8 张是自动均匀抽取的，无法控制风格倾向。** 如果想让风格更"星空"，有两种做法：

1. **保证 trainA 全部是星空**（最简单，让自动抽取自然得到星空目标）
2. **手工编辑 `style_refs.json`**，显式指定 8 张最具代表性的图

**我建议做法 1 + 手动精选 trainA**，因为自动抽取的机制会保持多样性。

---

## 4. 训练计划（分四阶段）

### 阶段 0：环境与数据准备（0.5 天）

| 步骤 | 命令/动作 | 产出 |
|---|---|---|
| 0.1 | 安装 PyTorch 2.11 + CUDA（本机 RTX 4060 8GB 可用） | 训练环境 |
| 0.2 | 收集星空图 100–200 张 → `trainA/testA` | 风格集 |
| 0.3 | 收集日常照片 200–400 张 → `trainB/testB` | 内容集 |
| 0.4 | `python ml/style_transfer/prepare.py --dataset <dir> --out reports/star/data` | `manifest.json` |
| 0.5 | **人工检查 `style_refs.png`**（脚本自动生成） | 确认 8 张风格图合适 |

⚠️ **注意本机现状**：当前 Python 环境**没有 torch**（我实测 `ModuleNotFoundError`），也没有 conda/venv。GPU 是 RTX 4060 Laptop 8GB。

### 阶段 1：教师模型训练（1 天）

```powershell
python ml/style_transfer/train.py --manifest reports/star/data/manifest.json `
    --out reports/star/teacher --kind teacher --steps 2500 --batch 6 --validate-every 250
```

**教师的作用**：提供"理想风格"的蒸馏目标。教师用 InstanceNorm，**可以在任意分辨率工作**，所以它不受 160×120 限制——这是绕过难点一的唯一途径。

**新增建议**：教师训练完后，**用 640×480 的真实分辨率图片测试教师输出**（不仅仅看 256×256 的验证图），确认星点在教师输出中确实存在。

### 阶段 2：学生训练 + QAT（1–2 天）

```powershell
# 主训练
python ml/style_transfer/train.py --manifest reports/star/data/manifest.json `
    --out reports/star/student --kind student `
    --teacher reports/star/teacher/step_002500.pt `
    --steps 8000 --batch 12 --qat-after 5500 --validate-every 500
```

**星空专用的超参调整建议**：

| 参数 | Monet 值 | 星空建议 | 理由 |
|---|---|---|---|
| `--style-weight` | 1500 | **2000–3000** | 星点统计弱，需加大风格权重补偿 |
| `--content-weight` | 1 | 1（不变） | 保持结构 |
| `--distill-weight` | 5 | **10–20** | 强化对教师（高分辨率）的模仿 |
| `--qat-after` | 5500 | 5500（不变） | 沿用 |
| 训练尺寸 | 256 | **考虑 384 或 512** | 见下方讨论 |

**关于提高训练分辨率**：`image_tensor(size=256)` 是硬编码默认值。若改成 384/512，学生的训练内部分辨率会提升到 96×96 / 128×128，**更接近推理时的 160×120**——这可能显著改善星点保留。

代价：8GB 显存可能吃紧（batch 需下调），训练时间增加。

**我建议先跑一版 256 的基线，再跑一版 512 的对比**，用同一批验证图看星点保留度。

### 阶段 3：标定与导出（0.5 天）

```powershell
# 激活值标定
python ml/style_transfer/calibrate.py --checkpoint reports/star/student/step_008000.pt `
    --manifest reports/star/data/manifest.json --out reports/star/calib

# 导出（生成 coeff.hex）
python ml/style_transfer/export.py --checkpoint reports/star/student/step_008000.pt --out reports/star/export
python ml/style_transfer/program.py --model reports/star/export --out rtl/style/model
```

**验证**：`export.py` 会输出 `maximum_affine_abs_bound`，必须 < 2^63（脚本内有断言）。同时会跑整数 vs FP 的 PSNR 检查。

### 阶段 4：硬件集成与实板验证（1 天）

```powershell
python tools/prepare_style_firmware.py   # 复制 style_weights.h + 生成自测向量
python tools/build_firmware.py           # 需要 RISC-V 工具链
python tools/run_style_checks.py         # 回归测试
# Efinity 重新综合（因为 coeff.hex 变了）
```

⚠️ **两个实测到的拦路虎**：

| 问题 | 现状 | 影响 |
|---|---|---|
| **RISC-V 工具链未安装** | `riscv-none-elf-gcc` 全盘不存在 | **无法重建 ELF** |
| **固件源码编译依赖** | `build_firmware.py` 需要 `SOC_RISCV_TOOLCHAIN` | 同上 |

**这意味着阶段 4 的固件重建目前做不了**。两个选项：
1. 安装 Efinity RISC-V IDE 2026.1（`C:/Efinity/efinity-riscv-ide-2026.1`）
2. **只更新 bitstream**（因为 `coeff.hex` 编进 FPGA ROM，固件不下载也能工作——但需确认 `style_driver.c` 是否强制下载）

---

## 5. 风险与缓解

| 风险 | 严重度 | 缓解措施 |
|---|---|---|
| **星点在 160×120 内被摧毁** | **高** | 提高训练分辨率；加强 distill；接受"星云块"效果 |
| **RAM 已 100% 占满** | **高** | 无法加大网络或缓存；只能改**权重值**，不能改结构 |
| **DSP 仅余 20 个** | 中 | 同样限制网络变更 |
| **RISC-V 工具链缺失** | 中 | 安装 IDE，或只更新 bitstream |
| **训练/推理分辨率不匹配** | 中 | 用 640×480 验证教师输出 |
| **星空数据集版权** | 低 | 优先用 NASA/ESO 公开图 |
| **4× 降采样是架构固有的** | **高** | 若必须保留星点，需改网络结构——但受 RAM 限制可能不可行 |

---

## 6. 我的判断与建议

### 6.1 的现实预期

基于对架构的核查，**我预计直接训练星空会得到**：

- ✅ 星空的**色调**（深蓝/紫色调）能迁移成功
- ✅ 星云的**大尺度云状纹理**能部分呈现
- ❌ **单颗星点会丢失或严重模糊**
- ⚠️ 效果可能类似"雾状蓝紫色调滤镜"，而非"星空"

### 6.2 若要真正做出星点效果，需要

**改变架构或处理流程**，例如：

| 方案 | 说明 | 可行性 |
|---|---|---|
| **提高 CNN 输入分辨率** | 让 enc 只降采样一次（320×240 内部） | 需改 RTL + 重新评估资源 |
| **旁路星点增强** | 在 CNN 后加一级高频增强（非学习） | 可在 RTL 做，占资源少 |
| **双路：CNN 做色调 + 原图做星点** | 混合 CNN 输出与原图高频 | 显示链可做，不占 CNN 资源 |

**但我必须指出**：RAM 已 **256/256 用满**，任何需要新增缓存/行缓冲的方案都必须先回收资源。这在 `DDR_READ_OPTIMIZATION.md` 里作者也明确说过。

### 6.3 建议的执行顺序

1. **先做小规模验证**（1 天）：只训练一版 256 分辨率的学生，用板子实测看星点是否真的丢失
2. **若效果可接受** → 按完整计划走
3. **若星点确实丢失** → 评估"旁路高频增强"方案（不需要改 CNN，只需在显示链加一级）

---

## 7. 需要你确认的事项

1. **原始数据集还在吗？** 我实测 `../archive` **不存在**。原 Monet 数据集的 B 域（照片）如果还在，可以直接复用
2. **星空图的来源与授权**？是否需要我推荐具体的公开图库
3. **是否接受"无星点、只有色调/星云"的效果**？这直接决定要不要动架构
4. **RISC-V 工具链**：是否安装 Efinity RISC-V IDE（用于重建固件）

---

## 附：关键文件清单

| 文件 | 作用 |
|---|---|
| `ml/style_transfer/prepare.py` | 数据集划分 + 风格参考选取 |
| `ml/style_transfer/train.py` | 教师/学生训练 |
| `ml/style_transfer/calibrate.py` | QAT 激活值标定 |
| `ml/style_transfer/export.py` | 导出 → `coeff.hex` / `coeff.bin` |
| `ml/style_transfer/program.py` | 生成硬件系数镜像 |
| `ml/style_transfer/evaluate.py` | 保留测试集评估 |
| `tools/prepare_style_firmware.py` | 生成 `style_weights.h` + 自测向量 |
| `tools/build_firmware.py` | 编译 ELF（需 RISC-V 工具链） |
| `tools/run_style_checks.py` | 全套回归测试 |
