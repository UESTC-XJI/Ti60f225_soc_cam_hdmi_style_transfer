# 报告清理计划

> 日期：2026-10-22
> 现状：`reports/ink` + `reports/analysis` 共 **75 个 md**（约 500 KB）
> 原则：**不删除任何内容**，只做「归档 + 索引」，保留全部历史可追溯性

---

## 一、现状问题

| # | 问题 | 说明 |
|---|---|---|
| **1** | **同主题的多个阶段报告混杂** | 如 burst 有 4 个（SWEEP / VERIFIED / BIG_WIN / FINDING），结论分散 |
| **2** | **ink 训练历史 16 个** | V1–V6 每个都有 PLAN + REPORT，共 16 个，占 21% |
| **3** | **过时/被推翻的报告无标记** | `MAC_ARRAY_WASTE.md`（前提错误）、`DIRECTION_B_RESULT.md`（已废弃）等仍与有效报告同级 |
| **4** | **无统一索引** | 75 个文件名，无法快速找到「当前结论」 |
| **5** | **结论矛盾** | 早期报告说 burst 有效 / 后期说失败，无版本提示 |

---

## 二、清理方案（三层次）

### 层次 1：归档历史实验（不动内容，只移动）

建立 `reports/archive/` 子目录，把**已完整结案**的报告移入：

| 归档目录 | 内容 | 文件数 |
|---|---|---|
| `archive/ink_training_v1_v6/` | INK_BW_V1..V6 的 PLAN + REPORT | **16** |
| `archive/burst_experiments/` | burst 的 4 个报告（最终结论另存 CUR2） | **4** |
| `archive/direction_experiments/` | DIRECTION_A/B、RESIDUAL_OPT、MAC_ARRAY_WASTE | **4** |
| `archive/early_analysis/` | 10-13 ~ 10-16 的早期分析 | **14** |
| `archive/migration/` | REMOTE_* / MIGRATION_* / SPLIT_* | **6** |

**归档后 `reports/ink` 剩约 21 个当前有效报告。**

### 层次 2：建立主索引 `reports/README.md`

一个文件搞定「我现在该看什么」：

```
# 项目报告索引
## 当前结论（必读，3 个）
- CUR_PERF.md        ← 性能现状（MS/帧率/已证伪清单）
- CUR_MODEL.md       ← 模型现状（ch24 可用 / ch12 失败 / ch16 训练中）
- CUR_BOARD.md       ← 板子状态（烧什么、怎么烧、判据）

## 历史报告（归档）
- archive/...        ← 全部保留
```

### 层次 3：写 3 个「当前结论」汇总文件

把散落在 75 个文件里的**当前结论**浓缩成 3 个：

| 文件 | 内容 | 来源合并 |
|---|---|---|
| **CUR_PERF.md** | 性能全景：83ms→79ms 历程、6 项已证伪、剩余方向 | PERF_83MS_BREAKDOWN + BURST_SWEEP + PITCH_ALIGN_WIN + BOARD_FAIL_* + GAP_11MS_RESOLVED + ALL_DIRECTIONS_SUMMARY |
| **CUR_MODEL.md** | 模型全景：ch24 可用、ch12 失败诊断、ch16 配方问题 | MODEL_SWITCH_VALIDATION + CH12_FULL_DIAGNOSIS + 本次配方发现 |
| **CUR_BOARD.md** | 板子操作手册：bit/固件配对、烧录步骤、遥测判据 | BOARD_WORKFLOW + BOARD_VERIFICATION_CHECKLIST + PANEL_SWITCH_VERIFIED |

---

## 三、执行清单

| 步骤 | 动作 | 影响 |
|---|---|---|
| 1 | 创建 `reports/archive/` 及 5 个子目录 | 新增目录 |
| 2 | 移动 **44 个**已结案报告到 archive | 仅移动，内容不变 |
| 3 | 写 **CUR_PERF.md / CUR_MODEL.md / CUR_BOARD.md** | 新增 3 个 |
| 4 | 写 `reports/README.md` 索引 | 新增 1 个 |
| 5 | `reports/ink` 保留 21 个当前有效报告 | — |
| 6 | git 提交（可完整回溯） | — |

### 保留在 `reports/ink` 的 21 个（当前有效）

| 类别 | 文件 |
|---|---|
| **板上实测（6）** | BOARD_RESULT_20261021 / BOARD_FAIL_BURST240 / BOARD_FAIL_UOF_DEADLOCK / BOARD_FINAL_CONCLUSION / BOARD_VERIFICATION_CHECKLIST / BOARD_WORKFLOW_20261021 |
| **性能优化（7）** | BURST_SWEEP / PITCH_ALIGN_WIN / STEP1_PAD_PITCH_DONE / GAP_11MS_RESOLVED / OPTIMIZATION_DIRECTIONS / OPTIMIZATION_STATUS / OFFLINE_OPTIMIZATIONS |
| **模型（3）** | MODEL_SWITCH_VALIDATION / CH12_FULL_DIAGNOSIS / PANEL_SWITCH_VERIFIED |
| **评估（5）** | COMPETITION_PROGRESS / COMPETITION_REQUIREMENTS_REVIEW / PARAM_SIZE_ANALYSIS / REMAINING_DIRECTIONS / ALL_DIRECTIONS_SUMMARY |

---

## 四、明确不做的事

| 不做 | 原因 |
|---|---|
| ❌ 删除任何报告 | 历史结论（含错误的）是排查依据，必须保留 |
| ❌ 修改历史报告内容 | 若要标注「已推翻」，只在新索引里说明，不改原文 |
| ❌ 合并正文 | 合并会丢失原始上下文和当时的推理链 |
| ❌ 动 `reports/ink/` 下的实验产物 | 只整理 `.md`，npz/pt/bin 等数据文件不动 |

---

## 五、预期效果

| 项 | 清理前 | 清理后 |
|---|---|---|
| `reports/ink` md 数 | 62 | **21** |
| `reports/analysis` md 数 | 13 | **0**（全部归档或合并进 CUR） |
| 找「当前结论」 | 翻 75 个文件 | **看 1 个 README → 3 个 CUR** |
| 历史可追溯 | 混杂 | **archive/ 分类保留** |
| 新增文件 | — | **4 个**（README + 3 CUR） |

---

## 六、执行顺序（确认后立即做）

```
1. mkdir reports/archive/{ink_training_v1_v6,burst_experiments,direction_experiments,early_analysis,migration}
2. git mv 44 个文件到对应归档目录
3. 写 CUR_PERF.md / CUR_MODEL.md / CUR_BOARD.md
4. 写 reports/README.md
5. git add + commit（一次提交，可完整回溯）
6. 验证：ls reports/ink/*.md = 21 个
```

**总耗时约 5 分钟，零风险（git 可回滚）。**
