# 水墨风格数据集汇总 + trainA/B、testA/B 作用说明

> 日期：2026-10-16
> 目标：为 Ti60F225 风格迁移 Demo 准备**中国水墨画**训练集/验证集
> 状态：数据已汇总、已划分、已校验；**待训练**（浮世绘 v15 正在占用 GPU）

---

## 一、先讲清楚：trainA/B、testA/B 到底是什么

这是 CycleGAN 体系的目录约定，**四个目录 = 两个域 × 两个用途**：

```
CIP_dataset1_process/
├── trainA/   域 A 的训练图
├── trainB/   域 B 的训练图
├── testA/    域 A 的测试图
└── testB/    域 B 的测试图
```

拆成两个维度看：

| 维度 | 含义 |
|---|---|
| **A / B** | **两个"域"（domain）**，即两种图像风格。CycleGAN 是**非配对**（unpaired）方法，A 和 B **不需要一一对应** |
| **train / test** | **用途**。train 用于训练，test 用于评估 |

### 1.1 A 与 B 的角色

以本项目（照片→水墨）为例：

| 目录 | 内容 | 在算法里的角色 |
|---|---|---|
| **A** | 水墨画 | **风格域（style target）** — 提供"要长成什么样" |
| **B** | 风景照片 | **内容域（content）** — 提供"画什么" |

对应两个生成器（`cycle_gan_model.py`）：

```
G_A : A → B      把水墨画变成照片
G_B : B → A      把照片变成水墨画     ← 这才是我们要的输出
```

**关键点**：训练时 A 的一张画和 B 的一张照片**随机配对**（`unaligned_dataset.py:70`），它们之间没有真实对应关系。网络靠**循环一致性损失**（cycle loss）学会"照片→水墨→照片"能还原回来，从而在无配对数据下学会风格迁移。

### 1.2 train 与 test 的作用

| 用途 | 说明 |
|---|---|
| **train** | 参与梯度更新，网络从中学习风格与内容 |
| **test** | **完全不参与训练**，只在最后评估效果，检验是否过拟合 |

`prepare.py` 实际上把数据分成**三份**（比 CycleGAN 原始的 train/test 更严格）：

| 划分 | 用途 |
|---|---|
| train | 训练 |
| validation | 训练过程中每 N 步看一次，用于调参/早停 |
| test | **最终只跑一次**，出报告 |

### 1.3 ⚠️ 一个必须注意的约定差异

**CIPGAN 与 TI60F225 板端工程的 A/B 定义是相反的！**

| 项目 | A 域 | B 域 | 照片→水墨的方向 |
|---|---|---|---|
| **CIPGAN**（`CIP_dataset1_process`） | **照片** | **水墨画** | `AtoB`（默认方向） |
| **板端工程**（`prepare.py`/`train.py`） | **画作（风格）** | **照片（内容）** | `BtoA` |

**证据**（我实际看图确认的）：

- CIPGAN 的 `testA/` 有 18 张**照片**（桂林、黄山、江南水乡）
- CIPGAN 的 `testB/` 有 1 张**水墨画**（`mountain.png`，墨色山石+留白）
- 板端的 `ukiyoe2photo`：`trainA` 562 张**浮世绘**，`trainB` 6287 张**照片**
- `prepare.py:50` 明确用 **domain A** 生成风格参考图：`paintings=[r['path'] for r in records if r['domain']=='A' ...]`

**含义**：
- 本报告交付的数据集按**板端工程约定**（A=画作，B=照片），可直接喂给 `ml/style_transfer/prepare.py` + `train.py` ✅
- 若要用 **CIPGAN 自己的 `train.py`** 训练，需要把 A/B 对调（或加 `--direction BtoA`）

---

## 二、水墨数据集汇总结果

### 2.1 数据来源

| 来源 | 数量 | 尺寸 | 可信度 | 说明 |
|---|---|---|---|---|
| **alicex2020**（WACV 2021 SAPGAN） | **2,192** | 512×512 | ✅ **博物馆来源** | 普林斯顿 362 / 哈佛 101 / 大都会 428 / 史密森尼 1,301 |
| ychen93（CS231N，网络爬取） | 5,914 | 256×256 | ⚠️ **含污染** | Google/Baidu 关键词爬取，**混有照片和水印图** |

论文引用：Xue et al., *End-to-End Chinese Landscape Painting Creation Using Generative Adversarial Networks*, WACV 2021（[arXiv:2011.05552](https://arxiv.org/abs/2011.05552)）

**另外发现**：[PKU-IMRE/ChipGAN](https://github.com/PKU-IMRE/ChipGAN)（专门做水墨迁移）只提供 11 张示例图，规模不足，仅作参考。

### 2.2 🔴 重要发现：网络爬取子集含照片污染

我在组装后做了**逐张视觉抽查**，确认 ychen93 子集混入了非画作：

| 文件 | 实际内容 |
|---|---|
| `ink_02003.jpg` | **儿童人像照片**（带博客水印 `joyye13.pixnet.net/blog`） |
| `ink_00819.jpg` | **黑马照片**（橙色渐变背景） |
| `ink_05996.jpg` / `ink_05872.jpg` | 带网站水印的扫描件 |

我最初用"肤色占比"启发式筛查，但**误报率极高**（35.8%）——因为中国画的**米黄绢本底色**本身就命中肤色规则。最终靠**按来源尺寸区分**（512=博物馆 / 256=爬取）+ 目视确认才定位准确。

**结论**：博物馆来源（512×512）**全部为真迹**，零污染；网络爬取来源（256×256）**混有照片**，不可直接用于训练。

### 2.3 交付的三个数据集

为不同实验目的提供三套，**都已完成 train/validation/test 划分**：

#### ① `ink_museum` — 推荐（博物馆来源，零污染）

```
_data/ink_museum/{trainA,testA,trainB,testB}
```

| 划分 | A（水墨画） | B（照片） |
|---|---|---|
| train | **1,678** | 5,507 |
| validation | **185** | 603 |
| test | **329** | 928 |

manifest：`reports/ink/data_museum/manifest.json`（3.4 MB）

#### ② `ink_mono` — 纯水墨（低饱和子集）

博物馆集中**水墨（monochrome）与设色（mineral colour）是混在一起的**。实测饱和度为 `sat < 0.15` 的纯水墨画只有 **380 张**：

| 划分 | A（纯水墨） | B（照片） |
|---|---|---|
| train | **275** | 5,507 |
| validation | **32** | 603 |
| test | **73** | 928 |

manifest：`reports/ink/data_mono/manifest.json`

#### ③ `ink2photo` — 全量（含爬取集，仅作对比）

```
_data/ink2photo/{trainA,testA,trainB,testB}
```

| 划分 | A | B |
|---|---|---|
| train | 6,285 | 5,507 |
| validation | 691 | 603 |
| test | 1,124 | 928 |

manifest：`reports/ink/data/manifest.json`
⚠️ **含照片污染，不建议作为主实验**

### 2.4 为什么 B 域（照片）可以复用

照片域**直接复用 `ukiyoe2photo`**（6,287 训练 / 751 测试），理由：

- CycleGAN 官方 `monet2photo`、`ukiyoe2photo`、`vangogh2photo` **共用同一批风景照片**（B 域完全相同）
- 这样水墨与浮世绘实验构成**严格的控制变量**——只有风格域变了，照片域一字不动

---

## 三、数据质量校验

### 3.1 饱和度分布（区分水墨/设色/照片）

| 数据集 | 域 | 平均饱和度 |
|---|---|---|
| ink_museum | A（画作） | **0.2825** |
| ink_museum | B（照片） | 0.3904 |
| ink_mono | A（纯水墨） | **< 0.15** |
| ink2photo | A（含污染） | 0.1855 |

照片域（0.39）与画作域（0.28）有清晰区分度。

### 3.2 水墨 vs 设色（关键风格决策）

中国画分两类，**风格目标不同**：

| 类型 | 饱和度 | 占比 | 视觉特征 |
|---|---|---|---|
| **水墨** | ≈ 0.00 | **17.7%**（sat<0.15） | 墨色浓淡、宣纸留白、题跋 |
| **设色** | 0.65–0.81 | 多数 | 青绿山水、金笺、矿物颜料 |

实测分布（博物馆 1,864 张训练图）：

```
sat < 0.10 :   121  ( 6.5%)
sat < 0.15 :   329  (17.7%)
sat < 0.20 :   612  (32.8%)
sat < 0.25 :   878  (47.1%)
```

**决策建议**：
- 要**典型水墨观感** → 用 `ink_mono`（但只有 275 训练图，偏少）
- 要**更好的训练稳定性** → 用 `ink_museum`（1,678 张），但输出会偏"设色山水"
- 折中：用 `ink_museum` 训练，但**风格参考图（Gram 目标）只选低饱和的那 8 张**

### 3.3 去重与划分

`prepare.py` 已执行：
- **dHash ≤ 4 连通分量去重**（防止近似图跨 train/test 泄漏）
- 原始 `test` 划分的近似组**全部保留为 test**
- 固定随机种子 `20261012`

### 3.4 一个已知的评估口径问题

`prepare.py` 的 `style_refs` **按文件名等间隔抽取**：

```python
styles=[paintings[i*(len(paintings)-1)//7] for i in range(8)]
```

这意味着风格目标图是**随机抽的**，不保证是典型水墨。上面那张"儿童照片"就是这样被抽进 `style_refs.png` 的（在 `ink2photo` 版本中）。**`ink_museum` 版本的风格参考图我已目视确认全部为真迹**。

---

## 四、与浮世绘实验的对照

| 项 | 浮世绘 | 水墨（museum） |
|---|---|---|
| A 域来源 | 官方 `ukiyoe2photo` | alicex2020 博物馆集 |
| A 域训练量 | 500 | **1,678** |
| B 域训练量 | 5,500 | 5,507（同一批照片） |
| 风格机制 | 大幅降饱和（−40%）、平涂色块 | **墨色浓淡 + 留白** |
| 网络容量 | 8,251 参数 | 同（拓扑不变） |
| 硬件载荷 | 11,056 B | 同 |

**好消息**：拓扑完全相同 → **RTL 不用改**，只需重训 + 换系数（`coeff.hex`）+ 重综合 bitstream。

---

## 五、复现命令

```powershell
# 环境
.venv\Scripts\python.exe

# 1) 生成划分清单（已执行）
.venv\Scripts\python.exe ml/style_transfer/prepare.py `
    --dataset _data/ink_museum --out reports/ink/data_museum

# 2) 教师训练（约 10 分钟）
.venv\Scripts\python.exe _train_local.py `
    --manifest reports/ink/data_museum/manifest.json --out reports/ink/teacher `
    --kind teacher --steps 2500 --batch 6 --validate-every 250

# 3) 学生训练 + QAT（约 46 分钟）
.venv\Scripts\python.exe _train_local.py `
    --manifest reports/ink/data_museum/manifest.json --out reports/ink/student `
    --kind student --teacher reports/ink/teacher/step_002500.pt `
    --steps 8000 --batch 12 --qat-after 5500 --validate-every 500

# 4) 标定 + 导出 + 生成 RTL 系数
.venv\Scripts\python.exe ml/style_transfer/calibrate.py `
    --checkpoint reports/ink/student/step_008000.pt `
    --manifest reports/ink/data_museum/manifest.json --out reports/ink/calib
.venv\Scripts\python.exe ml/style_transfer/export.py `
    --checkpoint reports/ink/student/step_008000.pt --out reports/ink/export
.venv\Scripts\python.exe ml/style_transfer/program.py `
    --model reports/ink/export --out rtl/style/model
```

---

## 六、待办与风险

| 项 | 说明 |
|---|---|
| **GPU 冲突** | 浮世绘 v15 正在训练（GPU 已占 **94.8%**），水墨训练需排队或换机器 |
| **部署单点** | `rtl/style/model/`、`software/firmware/style_*.h` 被多风格共用，**必须串行切换**；`style_selftest.h` 的自测向量必须与系数同源 |
| **RAM 已满** | 浮世绘版本 RAM 256/256（100%），**无扩容空间**，只能换权重 |
| **纯水墨样本少** | `ink_mono` 仅 275 训练图，可能欠拟合 |
| **未做去污** | `ink2photo` 含照片污染，如要使用需先过滤 |

---

## 七、证据文件

| 文件 | 内容 |
|---|---|
| `evidence/ink_pool_montage.png` | 原始池 30 张抽样（确认画作来源正确） |
| `evidence/ink_vs_coloured.png` | 上排纯水墨（sat=0.00）vs 下排重设色（sat=0.65~0.81） |
| `evidence/suspect_02003.png` | **污染样本**：混入的儿童照片（带博客水印） |
| `evidence/provenance.json` | 按来源的数量统计 |
| `dataset_card.png` | 四个目录的抽样总览（trainA/testA/trainB/testB） |

---

## 八、一句话总结

> 已汇总 **8,109 张可用中国画**（博物馆来源 2,192 张零污染 + 网络爬取 5,914 张含污染），
> 按板端约定（**A=画作、B=照片**）组装成三套带 train/validation/test 划分的数据集。
> 照片域复用 `ukiyoe2photo`，与浮世绘实验构成严格控制变量。
> **推荐 `ink_museum`（1,678 训练图，零污染）**；若要典型水墨观感用 `ink_mono`（275 张）。
> ⚠️ 注意 CIPGAN 自身的 A/B 定义与板端**相反**。
