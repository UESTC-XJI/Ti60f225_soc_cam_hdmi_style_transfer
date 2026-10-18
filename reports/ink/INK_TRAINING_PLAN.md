# 水墨风格训练计划

> 日期：2026-10-16
> 目标：把 Ti60F225 风格迁移 Demo 的风格从 Monet / 浮世绘换成**中国水墨画**
> 前提：数据集已就绪（`_data/ink_museum`、`_data/ink_mono`）；**GPU 当前被浮世绘 v15 占用**

---

## ⭐ 已确认方案（FROZEN — 待 GPU 空闲后执行）

**状态：方案已定稿，训练未启动**（v15 仍在跑，step 4850/5000）

### 决策表

| 项 | 确定值 | 依据 |
|---|---|---|
| **风格目标** | **广义中国画**（非经典黑白水墨） | identity 与 style 方向一致（实测差 0.022） |
| **数据集** | **`ink_museum`** | 1,678 训练图，零污染，子风格完整 |
| **参考图** | **32 张分层抽样** | 消除 68% 偏差，稳定性 2.0×，离上限有安全余量 |
| **训练尺寸** | **512** | 与 v15 一致，内部 128×128（更接近推理的 160×120） |
| **训练脚本** | `tools/analysis/_train_v2.py` | 唯一含 tone/quantile/cast 损失项 |
| **identity 权重** | **10（默认）** | 广义中国画目标下不冲突 |
| **量化上限** | refs ≤ **64**（size=512） | `torch.quantile` 的 2²⁴ 限制 |

### 需要执行的唯一准备动作

把分层参考图启用（**训练前必须做**）：

```powershell
# 备份原 8 张版本，启用 32 张分层版本
Copy-Item reports\ink\data_museum\style_refs.json `
          reports\ink\data_museum\style_refs.json.bak8 -Force
Copy-Item reports\ink\data_museum\style_refs_stratified.json `
          reports\ink\data_museum\style_refs.json -Force
```

### 训练命令（GPU 空闲后）

```powershell
# 预览（不执行）
.venv\Scripts\python.exe tools\analysis\_run_ink.py --stage all --dry-run

# 正式执行（四阶段，约 6.5 小时）
.venv\Scripts\python.exe tools\analysis\_run_ink.py --stage all
```

### 已内置的两道安全闸

| 闸 | 作用 |
|---|---|
| **refs 数量检查** | refs > 64（size=512）时**启动即报错退出**，并给出修复建议 |
| **STYLE_ORACLE_DIR** | 固件阶段自动指向水墨 export，避免自测向量错用浮世绘 |

（refs 闸已实测：设 100 张时正确报错并退出、退出码 1）

---

## 0. 前置状态核查（已实测）

| 项 | 状态 |
|---|---|
| 数据集 | ✅ `ink_museum`（A=2192 / B=7038）、`ink_mono`（A=380） |
| 划分 manifest | ✅ `reports/ink/data_museum/`、`reports/ink/data_mono/` |
| 污染数据 | ✅ 已删除（`ink_pool`、`ink2photo`） |
| 训练脚本 | ✅ `tools/analysis/_train_v2.py`（44 KB，含全部损失项） |
| 浮世绘 v15 | ⏳ **运行中**：step 4850/5000，QAT 阶段，GPU 93.4% |
| 一键驱动脚本 | ✅ `tools/analysis/_run_ink.py`（含 refs 闸 + oracle 修复） |
| 单进程包装器 | ✅ `tools/analysis/_train_local.py`（沙箱禁止命名管道时用） |

### ⚠️ 关键：必须用 `_train_v2.py`，不是 `ml/style_transfer/train.py`

两者参数差异很大：

| 损失项 | `train.py` | `_train_v2.py` |
|---|---|---|
| content / style / distill / TV | ✅ | ✅ |
| **tone**（色调匹配） | ❌ | ✅ |
| **quantile**（分位数匹配） | ❌ | ✅ |
| **cast**（色偏） | ❌ | ✅ |
| **sky**（天空） | ❌ | ✅ |
| **grain / stroke**（颗粒/笔触） | ❌ | ✅ |
| **identity** | ❌ | ✅ |
| `--size` | 固定 256 | **可配（v15 用 512）** |

**证据**：v15 的 `config.json` 含 `tone_weight`、`stroke_weight`，这些只在 `_train_v2.py` 中存在。

---

## 1. 为什么水墨需要不同的损失配置

### 1.1 水墨的风格特征（实测）

| 特征 | 数值 | 说明 |
|---|---|---|
| 饱和度 | **≈ 0.00**（纯水墨） | 墨色只有明度变化 |
| 纸底 | 米黄/留白，**R−B ≈ +35** | 宣纸/绢本偏暖 |
| 高频 | 笔触边缘 | 但受 160×120 瓶颈限制 |
| 对比 | 高（浓墨 vs 留白） | |

### 1.2 与浮世绘的关键差异

| 风格 | 机制 | 训练重点 |
|---|---|---|
| Monet | 保饱和、压对比 | tone + style |
| 浮世绘 | **大幅降饱和**（−40%）、平涂色块 | tone + stroke（笔触/轮廓） |
| **水墨** | **近乎去色 + 暖纸底 + 留白** | **tone（关键）+ quantile + cast** |

**核心难点**：VGG 特征是 mean/std 归一化的，**Gram 损失对全局亮度/色调是盲的**（`_train_v2.py` 头部注释已实测确认）。水墨最关键的"墨色浓淡"正是全局色调问题，**必须靠 tone/quantile 项约束**，不能只靠 style。

---

## 2. 训练流程（四阶段）

> ✅ **已提供一键驱动脚本** `tools/analysis/_run_ink.py`（含水墨专用损失配置与 oracle 修复）：
>
> ```powershell
> .venv\Scripts\python.exe tools\analysis\_run_ink.py --stage all --dry-run   # 先预览
> .venv\Scripts\python.exe tools\analysis\_run_ink.py --stage all             # 全流程
> .venv\Scripts\python.exe tools\analysis\_run_ink.py --stage teacher         # 单阶段
> ```
> 加 `--dataset mono` 切换到纯水墨子集。

```
① 教师训练（Teacher，1.38M 参数）
        ↓
② 学生训练 + QAT（Student C24/R4，8251 参数）
        ↓
③ 标定 + 导出 INT8 系数
        ↓
④ 生成 RTL 系数 + 固件头
```

### 阶段 ① 教师训练

```powershell
.venv\Scripts\python.exe tools\analysis\_train_v2.py `
    --manifest reports/ink/data_museum/manifest.json `
    --out reports/ink/teacher `
    --kind teacher --steps 2500 --batch 6 `
    --size 512 --validate-every 250
```

- 预计 ~56 分钟（按 v15 实测 1.783 s/step × batch 6/8，2500 步）
- 产出 `reports/ink/teacher/step_002500.pt`

### 阶段 ② 学生训练 + QAT

```powershell
.venv\Scripts\python.exe tools\analysis\_train_v2.py `
    --manifest reports/ink/data_museum/manifest.json `
    --out reports/ink/student `
    --kind student --teacher reports/ink/teacher/step_002500.pt `
    --steps 8000 --batch 12 --qat-after 5500 `
    --size 512 --validate-every 500
```

- 预计 **~6 小时**（按 v15 实测 1.783 s/step × batch 12/8，8000 步 ≈ 357 min）
- `--qat-after 5500`：前 5500 步 FP，之后量化感知训练

### 阶段 ③ 标定 + 导出

```powershell
# 激活值标定（6 种候选，取最优）
.venv\Scripts\python.exe ml\style_transfer\calibrate.py `
    --checkpoint reports/ink/student/step_008000.pt `
    --manifest reports/ink/data_museum/manifest.json `
    --out reports/ink/calib

# 导出 INT8 整数参考
.venv\Scripts\python.exe ml\style_transfer\export.py `
    --checkpoint reports/ink/student/step_008000.pt `
    --out reports/ink/export
```

**验收门槛**（参照浮世绘实测）：
- 整数 vs QAT MAE **< 1.5 LSB**
- PSNR **> 40 dB**
- 载荷 **11,056 B**（拓扑不变，尺寸必须一致）

#### ℹ️ 关于标定步骤：**可跳过，不影响结果**（已核验）

`calibrate.py` 会产出 `reports/ink/calib/scales.json`（6 种候选的 PSNR），
但**全仓库没有任何脚本读取它** —— `export.py:20` 只从 checkpoint 的
`config['activation_scales']` 取 scale，而该字段实测为 `None`。

**这是良性的**，因为默认 scale 恰是标定最优候选：

| 项 | 值 |
|---|---|
| `Student` 默认（`model.py:19`） | 22 层 `1/16` + 末层 `1/128` |
| 浮世绘标定最优候选 | **`global_1_16` = 22 层 `1/16` + 末层 `1/128`** |
| 实测 PSNR | `global_1_16` **37.70 dB** vs `calibrated` 34.39 dB |

即**标定的结果反而略差于默认值**，且两者逐层一致（已用 `Student.all_layers()` 核对：
22 层全部 `out_scale == 1/16`）。

**结论**：阶段③的标定用于**诊断/留档**，可保留；导出不必依赖它。
若后续想真正启用 `calibrated` scales，需要额外把 `scales.json` 注入
checkpoint 的 `config['activation_scales']`（当前链路未实现）。

### 阶段 ④ RTL 系数 + 固件

```powershell
.venv\Scripts\python.exe ml\style_transfer\program.py `
    --model reports/ink/export --out rtl/style/model

# ⚠️ 必须显式指定 oracle，否则自测向量会来自浮世绘
$env:STYLE_ORACLE_DIR = "reports/ink/export"
.venv\Scripts\python.exe tools\prepare_style_firmware.py
```

#### 🔴 已实测确认的陷阱（会导致板上自检失败）

`tools/prepare_style_firmware.py:11`：

```python
ORACLE = Path(os.environ.get('STYLE_ORACLE_DIR', ROOT/'reports/ukiyoe/export'))
if not (ORACLE/'parameters.npz').exists():
    ORACLE = ROOT/'ml/style_transfer/artifacts/integer'
```

| 项 | 来源 |
|---|---|
| 部署系数 | `rtl/style/model/style_weights.h`（**当前激活的风格**） |
| 自测 oracle | `reports/ukiyoe/export`（**硬编码默认**） |

**实测状态**（2026-10-16）：

```
reports/ukiyoe/export/parameters.npz  存在 ✅  → 不会触发回退，静默使用浮世绘
rtl/style/model/model.bin             当前是 ukiyoe export_v14（与 export 也不同）
```

**后果**：若把水墨系数写进 `rtl/style/model/` 后直接跑该脚本，`style_selftest.h` 会拿到**浮世绘的期望输出**。板上 CPU 自检时用"水墨输出 vs 浮世绘期望"比对 → **开机自检必然失败**，且**不会报错提示来源不对**。

这与浮世绘时记录的事故（`UKIYOE_RESULTS.md` §6.1，Monet/浮世绘 oracle 差异 4,204,124）是同一类问题，只是默认值从 Monet 换成了浮世绘。

**对策**：每次切换风格前**显式设置 `STYLE_ORACLE_DIR`**，并验证：

```powershell
# 确认三者同源（coefficients / oracle / selftest）
python -c "
import hashlib,pathlib
def h(p): return hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()[:16]
print('rtl/style/model/model.bin    ', h('rtl/style/model/model.bin'))
print('reports/ink/export/model.bin ', h('reports/ink/export/model.bin'))
print('match:', h('rtl/style/model/model.bin')==h('reports/ink/export/model.bin'))
"
```

---

## 3. 参数建议（针对水墨）

基于浮世绘 v15 的配置（`config.json`）做水墨适配：

| 参数 | 浮世绘 v15 | **水墨建议** | 理由 |
|---|---|---|---|
| `--size` | 512 | **512** | 与 v15 一致，便于对比 |
| `--content-weight` | 0.7 | 0.7 | 内容保持 |
| `--style-weight` | 1500 | 1500 | Gram 强度 |
| `--distill-weight` | 30.0 | 30.0 | 蒸馏 |
| `--tv-weight` | 0.0 | **0.0** | 水墨有笔触，不要过度平滑 |
| `--tone-weight` | 300.0 | **300~400** | **关键**：控制墨色浓淡 |
| `--quantile-weight` | 0.3 | **0.3~0.5** | **关键**：匹配明度分布 |
| `--cast-weight` | 1.0 | **1.0** | 暖纸底（R−B≈+35） |
| `--sky-weight` | 8.0 | **0（关闭）** | 水墨不需压天空蓝 |
| `--stroke-weight` | 15.0 | **0~15（可试）** | 水墨笔触比浮世绘轮廓弱 |
| `--grain-weight` | 1200.0 | **0（关闭）** | 水墨无版画颗粒 |
| `--identity-weight` | 10.0 | **10.0** | 稳定 |
| `--qat-after` | 3000/5000 | **5500/8000** | 按浮世绘早期 QAT 塌缩的教训，晚些进入 |

**建议先跑一版基准**（用上面的默认），再根据 validation 曲线调 tone/quantile。

---

## 4. 数据集选择建议

### 4.0 先确定目标：经典水墨 vs 广义中国画

这个选择决定了数据集和损失配置，**必须先定**。

| 目标 | 推荐数据集 | identity 权重 | 说明 |
|---|---|---|---|
| **经典水墨**（纯黑白） | `ink_mono` | **1~3** | 方向单一；identity 的"保色"倾向需压低 |
| **广义中国画**（推荐） | `ink_museum` | **10（默认即可）** | identity 与风格目标方向一致 |

**实测依据**（`reports/ink/evidence/`）：

| 目标 | A_train 均值 sat | refs 均值 sat | 差距 | 判定 |
|---|---|---|---|---|
| 广义中国画（museum） | 0.284 | 0.263 | 0.022 | ✅ **一致** |
| 经典水墨（mono） | 0.098 | 0.106 | 0.008 | ✅ 一致 |

在**广义中国画**目标下，identity loss（"中国画进→中国画出"）与 style_refs 指向**同一方向**，
不构成冲突，可用默认 `--identity-weight 10`。

> ⚠️ 只有把目标收窄成"经典水墨"时，museum 的 A_train（68% 非纯水墨）才会与目标相抵，
> 此时才需要降 identity 权重或改用 `ink_mono`。

### 4.1 数据集对比

| 数据集 | A 域训练量 | 优点 | 缺点 |
|---|---|---|---|
| **`ink_museum`** | **1,678** | 零污染，样本充足，**子风格完整**（水墨/浅绛/设色/青绿） | 含设色 |
| `ink_mono` | 275 | 纯水墨（sat<0.15） | 样本少，可能欠拟合 |

**museum 的子风格构成**（实测 n=900）：

| 子风格 | 饱和度 | 占比 |
|---|---|---|
| 水墨 | < 0.10 | 6.2% |
| 浅绛 | 0.10–0.20 | 26.0% |
| 设色 | 0.20–0.35 | 35.8% |
| 青绿/重彩 | > 0.35 | 32.0% |

**这正是一套完整的中国画子风格谱系**——对"广义中国画"目标是理想的覆盖。

### 4.2 🔴 真正的问题：8 张参考图不稳定（与子风格无关）

`prepare.py` 按文件名等间隔抽 8 张作为 `style_refs`，而**这 8 张唯一定义了风格**
（Gram 目标 + style_mean/std + 分位数）。问题是 n=8 的抽样方差太大。

Bootstrap 4000 次实测：

| 样本量 | 均值 sat 标准差 | p5..p95 | 波动幅度 |
|---|---|---|---|
| **n=8（当前）** | 0.0489 | 0.202 .. 0.363 | **57%** |
| **n=32（建议）** | 0.0246 | 0.241 .. 0.322 | **29%** |

即：**换个随机种子，风格目标就可能偏"水墨"或偏"青绿"**，训练结果不可复现。

**已生成修正版**：`reports/ink/data_museum/style_refs_stratified.json`

- 32 张，按子风格**分层比例抽样**（水墨 2 / 浅绛 8 / 设色 12 / 青绿 10）
- 均值 sat = **0.279**，逼近全集均值 0.281
- 稳定性提升 **2.0×**

使用方式：训练时把 `style_refs.json` 指向该文件（或直接替换）。

> 查看对比图：`evidence/style_refs_compare.png`（旧 8 张，混血）
> 与 `evidence/style_refs_32_stratified.png`（新 32 张，完整谱系）

> 📊 **参考图数量的完整分析见 [STYLE_REFS_ANALYSIS.md](STYLE_REFS_ANALYSIS.md)**
> 要点：数量对**训练速度无影响**（只在启动时用一次，N=64 约占任务时长 0.006%）；
> 存在**硬上限 N ≤ 64**（size=512 时，因 `torch.quantile` 的 2²⁴ 元素限制，
> 超出会在启动阶段直接崩溃）。**32 张是兼顾稳定性与安全余量的推荐值。**

---

## 5. 风险与注意事项

| 风险 | 说明 | 对策 |
|---|---|---|
| **GPU 冲突** | v15 占用 93.4%（7,646/8,188 MiB） | **等 v15 跑完**或换机器 |
| **部署单点** | `rtl/style/model/`、`software/firmware/style_*.h` 多风格共用 | **串行切换**，切换前确认三者同源 |
| **🔴 oracle 陷阱** | `prepare_style_firmware.py` 默认读 `reports/ukiyoe/export`，**静默**给出错误自测向量 | 已内置到驱动脚本（自动设 `STYLE_ORACLE_DIR`） |
| **🔴 refs 上限** | refs > 64（size=512）→ 启动即崩 | 已内置闸门（实测 100 张时正确报错退出） |
| **RAM 已满** | 浮世绘版本 256/256（100%） | 只能换权重，不能改结构 |
| **纯水墨样本少** | `ink_mono` 仅 275 训练图 | 主实验用 museum，mono 作对比 |
| **命名空间** | `reports/ink/*` 全新，勿与 `reports/ukiyoe/*` 混 | 严格分目录 |

---

## 6. 启动前检查清单

```powershell
# 0) 启用 32 张分层参考图（训练前唯一准备动作）
Copy-Item reports\ink\data_museum\style_refs.json `
          reports\ink\data_museum\style_refs.json.bak8 -Force
Copy-Item reports\ink\data_museum\style_refs_stratified.json `
          reports\ink\data_museum\style_refs.json -Force

# 1) GPU 是否空闲（应看到 used 降到 ~0）
nvidia-smi --query-gpu=memory.used,memory.total,utilization.gpu --format=csv

# 2) 数据集完整（应为 1864 / 328 / 6287 / 751）
.venv\Scripts\python.exe -c "import os;[print(d, len(os.listdir('_data/ink_museum/'+d))) for d in ['trainA','testA','trainB','testB']]"

# 3) manifest 可读
.venv\Scripts\python.exe -c "import json;m=json.load(open('reports/ink/data_museum/manifest.json',encoding='utf-8'));print(len(m['records']),'records')"

# 4) refs 已为 32 张、且不超上限 64
.venv\Scripts\python.exe -c "import json;r=json.load(open('reports/ink/data_museum/style_refs.json'));print(len(r),'refs')"

# 5) 训练脚本可导入
.venv\Scripts\python.exe tools\analysis\_train_v2.py --help

# 6) 一键预检（含 refs 闸 + oracle 检查）
.venv\Scripts\python.exe tools\analysis\_run_ink.py --stage all --dry-run
```

---

## 7. 与浮世绘实验的对照

| 项 | 浮世绘 | 水墨 |
|---|---|---|
| A 域来源 | 官方 `ukiyoe2photo` | alicex2020 博物馆集 |
| A 域训练量 | 500 | **1,678** |
| B 域训练量 | 5,500 | 5,507（**同一批照片**） |
| 风格机制 | 降饱和 + 平涂 | **去色 + 暖纸底 + 留白** |
| 网络容量 | 8,251 参数 | 同 |
| 硬件载荷 | 11,056 B | 同 |
| 主要损失 | tone + stroke | **tone + quantile + cast** |

**B 域完全相同 → 严格的控制变量**，可直接对比两种风格在同一架构下的表现。

---

## 8. 待办（方案已定稿，仅差执行）

**已完成（本轮）**
- [x] 数据集汇总与污染清理（`ink_museum` / `ink_mono`）
- [x] 确认风格目标 = 广义中国画（identity 不冲突）
- [x] 生成 32 张分层参考图并量化稳定性收益
- [x] 查明 refs 数量上限（64）并写入驱动脚本闸门
- [x] 确认 `prepare_style_firmware.py` oracle 机制并内置修复
- [x] 核实标定步骤可跳过（默认 scale 即最优）
- [x] 一键驱动脚本 `_run_ink.py` 通过 dry-run 与闸门测试

**待执行（需 GPU 空闲）**
- [ ] 启用 32 张分层参考图（唯一准备动作）
- [ ] 等浮世绘 v15 完成（当前 step 4850/5000）
- [ ] 阶段 ① 教师训练（~56 min）
- [ ] 阶段 ② 学生 + QAT（~6 h）
- [ ] 阶段 ③ 标定 + 导出（验证 MAE < 1.5 LSB，PSNR > 40 dB，载荷 11,056 B）
- [ ] 阶段 ④ RTL 系数 + 固件（**串行切换**，确认 oracle 同源）
- [ ] Efinity 重综合 bitstream
- [ ] 上板实测

> **本次未启动训练**（按要求仅确认方案）。GPU 空闲后执行
> `_run_ink.py --stage all` 即可，全程约 6.5 小时。
