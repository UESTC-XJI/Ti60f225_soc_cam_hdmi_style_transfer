# 黑白水墨数据集与训练计划（文件夹 `黑白ink`，版本 v1）

> 日期：2026-10-18
> 需求：整理一份**米黄背景不突出、色彩以黑白和浅色为主、狭义水墨**的训练集，
> 要求**风格化明显**；**不影响当前 v3 student 训练**
> 命名：数据集目录 **`_data/黑白ink`**，报告目录 **`reports/ink/data_黑白ink`**
> 版本：**v1**（模型输出 `reports/ink/teacher_黑白v1`、`student_黑白v1`）

---

## 一、需求的三条标准（已量化）

| # | 需求 | 量化指标 | 阈值 |
|---|---|---|---|
| **R1** | 米黄背景**不突出** | **背景区**（L>0.60）的 R−B | **< +0.04** |
| **R2** | 以黑白和浅色为主 | 饱和均值 + 近灰像素占比 | **sat < 0.18 且 pastel > 40%** |
| **R3** | 风格化**明显** | 与照片域的差距 | **style_score > 0.20** |

`style_score = (照片sat − 本集sat) + 0.5 × |本集lum − 照片lum|`

**为什么要分区测 R1**：全图 R−B 会把"暖纸底 + 大量黑墨"误判成暖调。
背景区单独测才反映"纸是否是米黄"。

---

## 二、实测：现有数据集都不符合

在 384px 上测（背景/暗区分开）：

| 来源 | 背景 R−B | 暗区 R−B | 背景% | 墨% | sat | pastel% | warm% |
|---|---|---|---|---|---|---|---|
| **museum A** | **+0.137** | +0.095 | 36.2% | 22.8% | **0.282** | 21.5% | **97.1%** |
| **mono A** | **+0.073** | +0.034 | 74.8% | 5.3% | 0.099 | 86.3% | 89.5% |
| PHOTOS | +0.099 | +0.027 | 24.2% | 46.7% | 0.378 | 22.8% | 59.5% |

| 判定 | C1 中性背景 | C2 黑白浅色 | C3 风格化 |
|---|---|---|---|
| museum | ❌ (+0.137 暖) | ❌ (sat 0.282) | ❌ |
| mono | ❌ (+0.073 仍暖) | ✅ (sat 0.099) | ✅ |

**结论**：
- **museum 的暖米黄背景很强（97% 像素偏暖）—— 与新需求完全相反**
- **mono 也偏暖（+0.073）**，但黑白浅色达标
- **严格筛选后本地只有 101 张可用**（museum 50 + mono 51）→ **太少**（通常需 500+）

**注意一个反直觉发现**：PHOTOS 自身的背景 R−B 也有 +0.099 ——
说明"背景偏暖"在照片里也常见（日落、暖光）。所以 **C1 必须与 C2/C3 联用**，
不能单独作为判据。

---

## 三、方案：联网补充（已实测可用来源）

Met Museum 的 `search` 端点已下线（**410 Gone**）。探测到的可用来源：

| 来源 | 状态 | 说明 |
|---|---|---|
| **Hugging Face** | ✅ 可用 | 多个水墨数据集 |
| **Art Institute of Chicago** | ✅ 可用 | 62119 条公版记录（但偏西方画作） |
| Wikimedia Commons | ❌ 分类为空 | 需换分类名 |
| Met API | ◐ 部分 | 单对象可取，search 已废弃 |

### 已选定下载（无 parquet 依赖）

**`takara-ai/Sumi-e_no_kurozuappu_ink_painting_closeups`**
- **1247 张图片文件**（本 venv 无 pyarrow/pandas，无法读 parquet → 必须选图片格式）
- **cc-by-4.0** 许可
- sumi-e = 水墨，与需求同族

**正在下载前 400 张**（约 1.64 MB/张，已下载 162 张）。

### 其他候选（parquet 格式，需先装 pyarrow）

| 数据集 | 规模 | 说明 |
|---|---|---|
| `mingyy/chinese_landscape_paintings` | 91 文件 77.6 GB | 中国山水 |
| `mingyy/chinese_landscape_paintings_1k` | 2.4 GB | 同族小版 |
| `WUYONGF/chinese_painting` | 1.5 GB | 综合中国画 |
| `Noveled/kr_ink_wash_painting_total_0927` | 51.4 GB | 韩国水墨 |
| `LazyLabChina/shuimodancai` | 5 张 | "水墨淡彩"，样本太少 |

---

## 四、构建流程（`tools/analysis/_build_neutral.py`）

1. 收集候选：新下载的 sumi-e + 本地严格合格的 museum/mono 子集
2. 逐张打分（背景 R−B、pastel、墨覆盖、对比）
3. 按 C1+C2 筛选 → 按 C3（风格化强度）排序
4. **dHash 去重**（防止近重复跨 split 泄漏）
5. 80/20 **按内容哈希**划分（可复现）
6. 输出 `manifest.json`（与 `_train_v2.py` 同 schema）+ 分层 `style_refs.json`

**关键设计**：**B 域（照片）直接复用现有集**，所以两种风格的**内容完全相同** ——
这是严格的对照实验，风格差异可直接归因。

---

## 五、训练计划（v1）

等 **v3 student 完成**后启动（当前 step 2475/5000，约 131 分钟）。

### 阶段① 教师 2500 步

```powershell
.venv\Scripts\python.exe tools\analysis\_train_v2.py `
  --manifest "reports/ink/data_黑白ink/manifest.json" `
  --out "reports/ink/teacher_黑白v1" `
  --kind teacher --steps 2500 --batch 6 --size 512 --validate-every 250 `
  --content-weight 0.7 --style-weight 1500 --distill-weight 30 `
  --tv-weight 0 --tone-weight 300 `
  --contrast-ratio 0.45 `
  --quantile-weight 0.3 `
  --cast-weight 0 `
  --grain-weight 550 --grain-target 0.0418 `
  --dark-hf-weight 0 `
  --sky-weight 0 --stroke-weight 0 --stroke-coarse-weight 0 `
  --identity-weight 3
```

### 与 v3 的差异（针对"黑白、去米黄"）

| 参数 | v3（暖纸底中国画） | **黑白v1** | 理由 |
|---|---|---|---|
| **`--cast-weight`** | 1（加暖调 +35 LSB） | **0** | **必须关掉** —— 这是"去米黄"的核心 |
| **`--cast-rgb`** | 0.0699,0,−0.0699 | （不适用） | — |
| **`--contrast-ratio`** | 0.65 | **0.45** | 水墨对比更强（浓墨 vs 留白） |
| **`--identity-weight`** | 10 | **3** | 目标为狭义水墨，降低"保色"倾向 |
| `--grain-weight` | 550 | **550** | 沿用（已验证命中） |

**注意**：`--cast-weight 0` 是**最关键的改动**。v3 的 R−B +0.150 正是暖纸底，
而新需求要求背景中性 —— 若保留 cast，会直接把输出推向米黄。

### 验收标准

| 指标 | 黑白水墨目标 | v3（对比） |
|---|---|---|
| **背景 R−B** | **< +0.04** | +0.150 ❌ |
| **sat** | **< 0.18** | 0.306 ◐ |
| **pastel 占比** | **> 40%** | — |
| style_score | **> 0.20** | — |
| 稳定性 | 无发散 | ✅ |

---

## 六、风险与陷阱

| 风险 | 说明 | 对策 |
|---|---|---|
| **🔴 GPU 冲突** | v3 student 占用 7.8 GB、100% | **等它完成**（约 131 分钟） |
| **🔴 cast 未关** | 保留 cast 会直接输出米黄 | **`--cast-weight 0` 必须** |
| **样本不足** | 严格筛选后可能不足 500 | sumi-e 补 400 + 本地 101 → 约 500 |
| **风格太单一** | sumi-e 是日本水墨，非中国 | 与本地中国画混合（已在流程中） |
| **R1 判据被照片误导** | 照片背景 R−B 也 +0.099 | **C1 必须与 C2/C3 联用** |
| **oracle 陷阱** | 固件自测向量默认来自 ukiyoe | 导出时**必须**设 `STYLE_ORACLE_DIR` |

---

## 七、待办

- [ ] 完成 sumi-e 下载（162/400）
- [ ] 运行 `_build_neutral.py` 构建数据集
- [ ] 验证新集：C1/C2/C3 达标率 + 风格化强度
- [ ] **等 v3 student 完成**
- [ ] 跑黑白水墨 v1 教师（2500 步）
- [ ] 验收；达标后跑学生
- [ ] 导出 → RTL → 固件（**串行 + oracle 同源**）

---

## 八、诚实边界

| 项 | 状态 |
|---|---|
| 三条标准已量化 | ✅ |
| 现有 museum/mono 不符合 R1 | ✅ 实测（+0.137 / +0.073） |
| 本地严格可用仅 101 张 | ✅ 实测 |
| sumi-e 来源可用、许可合规 | ✅ 实测（cc-by-4.0、图片文件） |
| **能否凑够 500 张合格** | ❌ **未知**，待下载完成后测 |
| **黑白 v1 能否风格化明显** | ❌ **未知**，需训练验证 |
