# 浮世绘（Ukiyo-e）风格迁移：任务规划

> 目标：把 Ti60F225 风格迁移 Demo 的风格目标换成**浮世绘**。
> 本文所有约束均来自对仓库代码与产物的实测核查。

---

## 1. 结论先行：浮世绘比星空更适合这个架构

这是本规划最重要的判断，依据是**特征尺度与网络瓶颈的匹配关系**。

### 1.1 网络瓶颈（实测）

我逐层核对了 `rtl/style/model/graph.json`：

```
640×480 --enc.0 s2--> 320×240 --enc.1 s2--> 160×120
                                              ↓
                        4 个 res 块全部在 160×120
                                              ↓
            160×120 --dec up2--> 320×240 --dec up2--> 640×480
```

- **总编码步长 = 4×**，CNN 实际只在 **160×120** 运算
- 瓶颈处一个 3×3 卷积对应 **12×12 = 144 个输入像素**

### 1.2 特征尺度对照

| 特征 | 输入尺度 | 经 4× 瓶颈后 | 判定 |
|---|---|---|---|
| 星点（1 px） | 1 px | 0.25 px | **摧毁** |
| 星点（2 px） | 2 px | 0.5 px | **摧毁** |
| 浮世绘轮廓线（2–3 px） | 2–3 px | 0.5–0.75 px | 边缘（marginal） |
| **浮世绘平涂色块** | 50–500 px | 12–125 px | **保留** |
| **浮世绘波浪/云纹** | 20–100 px | 5–25 px | **保留** |
| **浮世绘配色** | 全局 | 全局 | **保留** |
| 木纹质感 | 3–8 px | 0.75–2 px | 部分 |

**核心洞察**：
- 星空依赖**稀疏的 1–2 像素点高光** → 小于瓶颈 → 丢失
- 浮世绘依赖**平涂色块 + 强配色 + 中尺度纹样** → 大于瓶颈 → 保留

**所以同一个架构对浮世绘的表现会明显好于星空。** 这不是推测，是从尺度关系直接推出的。

### 1.3 但仍有一个弱点需要正视

**浮世绘的轮廓线（2–3 px）处在瓶颈边缘**。若线条被削弱，画面会失去"版画感"而变成"模糊色块"。

这是本计划需要重点处理的风险，对策见 §5。

---

## 2. 现状核查（实测事实）

### 2.1 硬件约束（与星空计划相同，未变）

| 资源 | 使用 | 容量 | 占用率 | 余量 |
|---|---|---|---|---|
| XLR | 57,870 | 60,800 | **95.2%** | 2,930 |
| RAM | 256 | 256 | **100%** | **0** |
| DSP | 140 | 160 | 87.5% | 20 |

来源：`reports/style_demo/release_display_deadline/manifest.json`

**含义**：只能改**权重值**，不能改网络结构。`channels=24, blocks=4` 是硬编码的（`model.py:37`）。

### 2.2 训练超参（`train.py` 实测默认值）

| 参数 | 默认 | 位置 |
|---|---|---|
| `--content-weight` | 1 | `train.py:74` |
| `--style-weight` | **1500** | `train.py:75` |
| `--distill-weight` | 5 | `train.py:76` |
| TV 权重 | **0.03**（硬编码） | `train.py:123` |
| `--lr` | 1e-3（线性衰减到 10%） | `train.py:72,127` |
| 训练尺寸 | **256×256**（硬编码） | `train.py:32` |
| 数据增强 | **仅水平翻转** | `train.py:41` |
| 损失 | `content + 1500*style + .03*TV + 5*distill` | `train.py:123` |

### 2.3 训练/推理分辨率失配

| | 分辨率 | 内部分辨率 |
|---|---|---|
| 训练 | 256×256 | 64×64 |
| 推理 | 640×480 | **160×120** |

**失配 2.5×**（160/64）。这意味着网络在训练时看到的纹理尺度，与推理时**不同**。对浮世绘的轮廓线尤其不利——训练时 3 px 的线，推理时等效 7.5 px。

### 2.4 环境现状

| 项 | 状态 |
|---|---|
| PyTorch | **未安装**（`ModuleNotFoundError`） |
| GPU | RTX 4060 Laptop, 8 GB（当前占用 1.3 GB） |
| conda/venv | **不存在** |
| RISC-V GCC | **未安装** → 无法编译 ELF |
| 磁盘 | C: 50 GB / D: 169 GB 可用 |
| 数据集 | `../archive` **不存在**，原始数据已丢失 |

### 2.5 权重更新的两条路径（必须同步）

```
① FPGA ROM:  rtl/style/model/coeff.hex  →  $readmemh 编进 bitstream
             生成器: ml/style_transfer/export.py

② CPU 固件:  software/firmware/style_weights.h  →  编进 ELF，开机经 APB 下载
             来源: tools/prepare_style_firmware.py（原样复制 ① 的产物）
```

**单一数据源是 `export.py`。**

---

## 3. 数据集规划

### 3.1 目录结构（`prepare.py` 硬性要求）

```
<dataset>/
  trainA/   testA/     ← 风格图（浮世绘）
  trainB/   testB/     ← 内容图（日常照片）
```

`prepare.py` 的行为（实测）：
- 用 **dHash ≤4 连通分量**去重分组
- **自动保留原始 test 分组**（不跨 split 泄漏）
- 按 10% 划出 validation
- **自动**从 trainA 均匀抽 8 张作 Gram 目标 → `style_refs.json`

### 3.2 浮世绘风格图（A 域）建议

| 来源 | 说明 | 授权 |
|---|---|---|
| **Met Museum Open Access** | 大量浮世绘高清图 | CC0 / 公有领域 |
| **浮世绘美术馆（日本）** | 北斋、广重、歌麿等 | 需查具体条款 |
| **Library of Congress** | 部分日本版画 | 公有领域 |
| **WikiArt** | 聚合站，需查单图授权 | 混合 |

**建议 150–250 张**，覆盖三类风格：

| 类型 | 代表 | 特征 |
|---|---|---|
| **风景/波浪** | 葛饰北斋《神奈川冲浪里》 | 强线条、动态构图 |
| **花卉/静物** | 歌川广重 | 平涂色块、细腻渐变 |
| **人物/役者** | 东洲斋写乐 | 强轮廓、夸张表情 |

**混合三类**能让 Gram 目标涵盖"线条 + 平涂 + 配色"三个维度。

### 3.3 内容图（B 域）

**关键**：内容图要匹配板上实际使用场景（相机实时视频）。

| 建议 | 数量 | 理由 |
|---|---|---|
| 日常室内/室外照片 | 300–500 张 | 与相机输入分布一致 |
| 含人物、建筑、自然 | 混合 | 覆盖浮世绘常见的主题 |
| **避免纯风景大片** | — | 与实时视频分布不符 |

### 3.4 风格参考的手动精选（重要）

`prepare.py:50-52` 自动均匀抽 8 张：

```python
paintings=[r['path'] for r in records if r['domain']=='A' and r['split']=='train']
styles=[paintings[i*(len(paintings)-1)//7] for i in range(8)]
```

**问题**：自动抽取无法控制风格倾向。如果 trainA 混入了非典型浮世绘，Gram 目标会被污染。

**建议**：
1. 先保证 **trainA 全部是典型浮世绘**
2. 运行 `prepare.py` 后，**人工检查 `style_refs.png`**（脚本会生成 8 张拼图）
3. 若某张不合适，**手工编辑 `style_refs.json`** 替换

这一步不能省——Gram 目标直接决定风格输出。

---

## 4. 任务分解（按阶段）

### 阶段 0：环境与数据（1 天）

| # | 任务 | 产出 | 验收 |
|---|---|---|---|
| 0.1 | 搭建 PyTorch 环境 | venv + torch 2.11+cu128 | `import torch; torch.cuda.is_available()` 为 True |
| 0.2 | 收集浮世绘 150–250 张 | `trainA/` `testA/` | 人工抽查风格一致性 |
| 0.3 | 收集日常照片 300–500 张 | `trainB/` `testB/` | 与相机场景匹配 |
| 0.4 | 运行数据准备 | `manifest.json` `style_refs.json` | 输出 train/val/test 计数 |
| 0.5 | **人工检查 `style_refs.png`** | 确认 8 张风格图 | 必要时手工替换 |

**验收标准**：`manifest.json` 生成成功，`style_refs.png` 中 8 张图全部是典型浮世绘。

### 阶段 1：教师训练（1 天）

```powershell
python ml/style_transfer/train.py --manifest <manifest> `
    --out reports/ukiyoe/teacher --kind teacher `
    --steps 2500 --batch 6 --validate-every 250
```

| 项 | 说明 |
|---|---|
| 教师架构 | `Teacher`（`model.py:77`），用 **InstanceNorm**，**可在任意分辨率工作** |
| 参数量 | 约 1.4 M（`teacher.pt` 5.5 MB） |
| 损失 | `content + 1500*style + .03*TV`（无 distill） |

**关键动作**：训练完后**用 640×480 真实分辨率测试教师输出**，而不仅看 256×256 验证图。这是唯一能验证"轮廓线在推理分辨率下是否保留"的途径。

**验收标准**：640×480 的教师输出中，轮廓线清晰、色块平涂、配色符合浮世绘。

### 阶段 2：学生训练 + QAT（1–2 天）

```powershell
python ml/style_transfer/train.py --manifest <manifest> `
    --out reports/ukiyoe/student --kind student `
    --teacher reports/ukiyoe/teacher/step_002500.pt `
    --steps 8000 --batch 12 --qat-after 5500 --validate-every 500
```

**浮世绘专用超参调整建议**：

| 参数 | Monet 值 | 浮世绘建议 | 理由 |
|---|---|---|---|
| `--style-weight` | 1500 | **1200–1800** | 浮世绘风格统计强，不需过度加大 |
| `--content-weight` | 1 | **1–2** | 略提高以保住结构（浮世绘易"糊"） |
| `--distill-weight` | 5 | **10–20** | 强化对高分辨率教师的模仿 |
| `--qat-after` | 5500 | 5500 | 沿用 |
| 训练尺寸 | 256 | **试 512** | 见 §5.1 |

**注意**：`--content-weight` 和 `--style-weight` 是**此消彼长**的关系。浮世绘的"平涂"效果本身就意味着内容细节被简化，所以不建议把 content 提太高。

### 阶段 3：标定与导出（0.5 天）

```powershell
# 激活值标定（QAT 量化范围）
python ml/style_transfer/calibrate.py --checkpoint reports/ukiyoe/student/step_008000.pt `
    --manifest <manifest> --out reports/ukiyoe/calib

# 导出 → 生成 coeff.hex
python ml/style_transfer/export.py --checkpoint reports/ukiyoe/student/step_008000.pt `
    --out reports/ukiyoe/export
python ml/style_transfer/program.py --model reports/ukiyoe/export --out rtl/style/model
```

**验收标准**：
- `export.py` 的 `maximum_affine_abs_bound` < 2^63（脚本内断言）
- 整数 vs FP 的 PSNR 报告（脚本会输出）

### 阶段 4：硬件集成与实板验证（1 天）

```powershell
python tools/prepare_style_firmware.py   # 生成 style_weights.h + 自测向量
python tools/build_firmware.py           # ⚠️ 需要 RISC-V 工具链
python tools/run_style_checks.py         # 全套回归
# Efinity 重新综合（coeff.hex 变了）
```

⚠️ **阻塞项**：`riscv-none-elf-gcc` **未安装**，无法编译 ELF。

**两个选项**：
1. 安装 Efinity RISC-V IDE 2026.1
2. **只更新 bitstream**（`coeff.hex` 编进 FPGA ROM；需确认 `style_driver.c` 是否强制下载）

---

## 5. 针对浮世绘的三个专项优化

### 5.1 提高训练分辨率（最直接的改善）

**问题**：训练内部 64×64 vs 推理 160×120，**失配 2.5×**。

**做法**：修改 `train.py:32` 的 `image_tensor(size=256)` → `size=512`。

| | 256（现状） | 512（建议） |
|---|---|---|
| 训练内部 | 64×64 | **128×128** |
| 推理内部 | 160×120 | 160×120 |
| 失配 | 2.5× | **1.25×** |
| 显存 | ~4 GB | ~7 GB（接近 8 GB 上限，需降 batch） |
| 训练时间 | 基准 | 约 3–4× |

**收益**：轮廓线的训练/推理尺度更接近，线条保留更好。

**代价**：8 GB 显存吃紧，batch 需从 12 降到 4–6。

**建议**：**先跑 256 基线，再跑 512 对比**，用同一批验证图比较线条锐度。

### 5.2 降低 TV 权重（保住平涂边界）

**问题**：TV 损失（`0.03`，硬编码在 `train.py:123`）惩罚相邻像素差异，会**平滑掉边缘**。

对 Monet 这种柔和风格，TV 有助于画面干净。但**浮世绘依赖清晰边界**，TV 过强会让轮廓线糊掉。

**建议**：把 TV 从 `0.03` 降到 `0.01–0.02`。

**做法**：目前 TV 是硬编码，需要改成命令行参数：

```python
# train.py 新增
p.add_argument('--tv-weight', type=float, default=0.03)
# 并把 loss 里的 .03 换成 a.tv_weight
```

这是**唯一需要改代码**的地方（其他都是命令行参数）。

### 5.3 增加数据增强（提升泛化）

**问题**：当前只有水平翻转（`train.py:41`）。

**建议增加**：轻微的颜色抖动、小角度旋转、随机裁剪。

但要注意：**浮世绘的配色是风格核心**，颜色抖动会削弱风格学习。所以**只建议加几何增强**（旋转、裁剪），不加颜色增强。

---

## 6. 风险登记

| 风险 | 严重度 | 概率 | 缓解 |
|---|---|---|---|
| **轮廓线在 160×120 边缘被削弱** | 高 | 中 | 提高训练分辨率（§5.1）+ 降 TV（§5.2） |
| **RAM 100% 占满** | 高 | — | 只能改权重，不能改结构（不可绕过） |
| **RISC-V 工具链缺失** | 中 | 确定 | 安装 IDE，或只更新 bitstream |
| **数据集授权** | 中 | 低 | 优先 Met Museum CC0 |
| **风格参考自动抽取不合适** | 中 | 中 | 人工检查 + 手工编辑 `style_refs.json` |
| **8 GB 显存不足（512 训练）** | 中 | 中 | 降 batch，或用梯度累积 |
| **训练/推理尺度失配** | 中 | 高 | §5.1 |
| **浮世绘效果偏"糊"** | 中 | 中 | 降 TV + 提高 content-weight |

---

## 7. 时间估算

| 阶段 | 任务 | 估时 | 依赖 |
|---|---|---|---|
| 0 | 环境 + 数据 | 1 天 | 无 |
| 1 | 教师训练 | 1 天 | 阶段 0 |
| 2 | 学生训练 + QAT | 1–2 天 | 阶段 1 |
| 3 | 标定 + 导出 | 0.5 天 | 阶段 2 |
| 4 | 硬件集成 + 实板验证 | 1 天 | 阶段 3 + RISC-V 工具链 |
| | **合计** | **4.5–5.5 天** | |

**不含**：数据集收集的实际耗时（取决于来源与整理量）、环境搭建的调试时间。

---

## 8. 需要你确认的事项

1. **数据集来源与授权**
   - 是否接受用 Met Museum Open Access（CC0）？我可以列出具体的浮世绘藏品链接
   - 原 Monet 的照片集（B 域）是否还有备份？`../archive` 已不存在

2. **是否接受"平涂色块 + 强配色"作为主要效果**
   - 若是 → 按本计划走
   - 若还想要**清晰轮廓线** → 需要认真执行 §5.1（512 训练）+ §5.2（降 TV）

3. **RISC-V 工具链**
   - 是否安装 Efinity RISC-V IDE（约几 GB）用于重建固件？

4. **是否需要我改代码**
   - `--tv-weight` 参数化（§5.2）需要改 `train.py`
   - `image_tensor(size=512)` 需要改 `train.py:32`
   - 这两处改动很小，但会修改训练脚本

---

## 9. 与星空计划的对比

| 维度 | 星空 | **浮世绘** |
|---|---|---|
| 特征尺度 vs 瓶颈 | **小于**（1–2 px） | **大于**（平涂 50–500 px） |
| 预期效果 | 雾状色块，无星点 | **平涂色块 + 强配色 + 纹样** |
| 架构适配度 | ❌ 差 | ✅ **好** |
| 主要风险 | 星点必然丢失 | 轮廓线可能削弱（可缓解） |
| 建议 | 需改架构或加旁路 | **可直接训练** |

**结论**：浮世绘是这个架构的**合适目标**。建议优先推进浮世绘，星空需要额外的架构工作。

---

## 附：关键文件与命令

| 文件 | 作用 |
|---|---|
| `ml/style_transfer/prepare.py` | 数据划分 + 风格参考选取 |
| `ml/style_transfer/train.py` | 教师/学生训练（**§5.2 需改此文件**） |
| `ml/style_transfer/calibrate.py` | QAT 激活值标定 |
| `ml/style_transfer/export.py` | 导出 → `coeff.hex` |
| `ml/style_transfer/program.py` | 生成硬件系数镜像 |
| `ml/style_transfer/evaluate.py` | 保留测试集评估 |
| `tools/prepare_style_firmware.py` | 生成 `style_weights.h` |
| `tools/build_firmware.py` | 编译 ELF（需 RISC-V 工具链） |
| `tools/run_style_checks.py` | 全套回归 |

```powershell
# 完整流程（顺序执行）
python ml/style_transfer/prepare.py --dataset <dir> --out reports/ukiyoe/data
python ml/style_transfer/train.py --manifest reports/ukiyoe/data/manifest.json --out reports/ukiyoe/teacher --kind teacher --steps 2500 --batch 6 --validate-every 250
python ml/style_transfer/train.py --manifest reports/ukiyoe/data/manifest.json --out reports/ukiyoe/student --kind student --teacher reports/ukiyoe/teacher/step_002500.pt --steps 8000 --batch 12 --qat-after 5500 --validate-every 500
python ml/style_transfer/calibrate.py --checkpoint reports/ukiyoe/student/step_008000.pt --manifest reports/ukiyoe/data/manifest.json --out reports/ukiyoe/calib
python ml/style_transfer/export.py --checkpoint reports/ukiyoe/student/step_008000.pt --out reports/ukiyoe/export
python ml/style_transfer/program.py --model reports/ukiyoe/export --out rtl/style/model
python tools/prepare_style_firmware.py
python tools/build_firmware.py
python tools/run_style_checks.py
```
