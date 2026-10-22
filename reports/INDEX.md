# 项目报告索引

> 最后更新：2026-10-22
> **先看下面 3 个 CUR，再按需查深处的报告。** 历史过程全部保留在 `archive/`。

---

## ⭐ 当前结论（必读，3 个）

| 文件 | 内容 | 什么时候看 |
|---|---|---|
| [**CUR_PERF.md**](CUR_PERF.md) | **性能全景** —— MS 79ms/13fps、9 项已证伪、剩余方向、赛题缺口 | 想知道「现在多快」「还能怎么优化」 |
| [**CUR_MODEL.md**](CUR_MODEL.md) | **模型全景** —— ch24 可用、ch12/ch16 失败诊断、训练配方教训、RTL 约束 | 想知道「用哪个模型」「怎么训新的」 |
| [**CUR_BOARD.md**](CUR_BOARD.md) | **上板手册** —— bit/固件配对、烧录步骤、遥测判据、故障处置 | **每次上板前必读** |

---

## 一、一句话现状

| 项 | 当前 |
|---|---|
| **板子跑的** | `outflow_panelsw2`（ch24）+ `soc_video_app_v3.bin` |
| **帧率** | **双面板 11 fps / 单面板 12–13 fps**（赛题要 ≥15） |
| **模型** | `ink/student_v3`（8,251 参数，QAT，可上板） |
| **在训练** | `student_ch16b`（正确配方，约 5.2 小时） |
| **已证伪** | burst 加长、UOF=0、PAD_PITCH、prefetch、层间气泡、加 MAC、残差优化、3×3 预取 |

---

## 二、目录结构

```
reports/
├── README.md          ← 目录管理说明（原来就有）
├── INDEX.md           ← 本文件（报告索引入口）
├── CUR_PERF.md        ← ⭐ 性能结论
├── CUR_MODEL.md       ← ⭐ 模型结论
├── CUR_BOARD.md       ← ⭐ 上板手册
├── CLEANUP_PLAN.md    ← 本次清理说明
│
├── ink/               ← 21 个当前有效报告
│   ├── BOARD_*.md     ← 板上实测（6 个）
│   ├── BURST_*.md     ← burst 实验
│   ├── PITCH_*.md     ← pitch 对齐
│   ├── GAP_11MS_*.md  ← 11ms 定位
│   ├── CH12_*.md      ← ch12 诊断
│   ├── PANEL_*.md     ← 单面板实测
│   ├── COMPETITION_*.md ← 赛题评估
│   └── ...            ← 其它优化/评估
│
└── archive/           ← 54 个历史报告（全部保留，按主题分类）
    ├── ink_training_v1_v6/    (17) ink 风格 V1–V6 训练历史
    ├── early_analysis/        (24) 10-13~10-16 早期分析
    ├── migration/             (6)  远端架构迁移
    ├── direction_experiments/ (4)  方向 A/B、残差、MAC 阵列
    └── burst_experiments/     (3)  burst 早期实验
```

---

## 三、按主题查报告

### 性能优化

| 想知道 | 看 |
|---|---|
| 性能现在什么水平 | [CUR_PERF.md](CUR_PERF.md) |
| 哪些优化试过了、失败了 | [CUR_PERF.md](CUR_PERF.md) 第三节 |
| burst 为什么失败 | [ink/BOARD_FAIL_BURST240.md](ink/BOARD_FAIL_BURST240.md) |
| UOF=0 为什么死锁 | [ink/BOARD_FAIL_UOF_DEADLOCK.md](ink/BOARD_FAIL_UOF_DEADLOCK.md) |
| 那 11ms 到底是什么 | [ink/GAP_11MS_RESOLVED.md](ink/GAP_11MS_RESOLVED.md) |
| 脉动阵列可行吗 | [ink/ALL_DIRECTIONS_SUMMARY.md](ink/ALL_DIRECTIONS_SUMMARY.md) |
| burst 扫参曲线 | [ink/BURST_SWEEP.md](ink/BURST_SWEEP.md) |
| 离线能做什么 | [ink/OFFLINE_OPTIMIZATIONS.md](ink/OFFLINE_OPTIMIZATIONS.md) |
| 优化状态跟踪 | [ink/OPTIMIZATION_STATUS.md](ink/OPTIMIZATION_STATUS.md) |

### 模型

| 想知道 | 看 |
|---|---|
| 用哪个模型 | [CUR_MODEL.md](CUR_MODEL.md) |
| ch12 为什么失败 | [ink/CH12_FULL_DIAGNOSIS.md](ink/CH12_FULL_DIAGNOSIS.md) |
| 训练要什么参数（配方教训） | [CUR_MODEL.md](CUR_MODEL.md) 第三节 |
| 训新模型前查什么约束 | [CUR_MODEL.md](CUR_MODEL.md) 第四节 |
| 参数量为什么限 500KB | [ink/PARAM_SIZE_ANALYSIS.md](ink/PARAM_SIZE_ANALYSIS.md) |
| ink 风格 V1–V6 历史 | `archive/ink_training_v1_v6/` |

### 上板

| 想知道 | 看 |
|---|---|
| **怎么烧、烧什么** | [CUR_BOARD.md](CUR_BOARD.md) |
| 遥测数字多少算正常 | [CUR_BOARD.md](CUR_BOARD.md) 第三节 |
| 出故障怎么办 | [CUR_BOARD.md](CUR_BOARD.md) 第四节 |
| 编 bit 前查什么 | [CUR_BOARD.md](CUR_BOARD.md) 第六节 |
| 完整上板流程 | [ink/BOARD_WORKFLOW_20261021.md](ink/BOARD_WORKFLOW_20261021.md) |
| 验证清单 | [ink/BOARD_VERIFICATION_CHECKLIST.md](ink/BOARD_VERIFICATION_CHECKLIST.md) |
| 按键切换实测 | [ink/PANEL_SWITCH_VERIFIED.md](ink/PANEL_SWITCH_VERIFIED.md) |

### 赛题

| 想知道 | 看 |
|---|---|
| 赛题要求 vs 完成度 | [ink/COMPETITION_PROGRESS.md](ink/COMPETITION_PROGRESS.md) |
| 赛题技术提示对照 | [ink/COMPETITION_REQUIREMENTS_REVIEW.md](ink/COMPETITION_REQUIREMENTS_REVIEW.md) |
| 还差什么 | [ink/REMAINING_DIRECTIONS.md](ink/REMAINING_DIRECTIONS.md) |

---

## 四、⚠️ 被推翻的结论（避免重犯）

| 曾经的判断 | 实际情况 | 详见 |
|---|---|---|
| 「读侧 3.79× 重复读，可大降」 | 实际只 **1.22×** | [CUR_PERF.md](CUR_PERF.md) 第七节 |
| 「1×1 层浪费 11/12 taps」 | **错**：taps 映射 12 输入通道，利用率 43.5% | `archive/direction_experiments/MAC_ARRAY_WASTE.md` |
| 「burst 加长省 21.3%」 | **仿真对，实板更差**（仿真无仲裁竞争） | [ink/BOARD_FAIL_BURST240.md](ink/BOARD_FAIL_BURST240.md) |
| 「UOF=0 是单参数优化」 | **是功能前提**，关掉即死锁 | [ink/BOARD_FAIL_UOF_DEADLOCK.md](ink/BOARD_FAIL_UOF_DEADLOCK.md) |
| 「11ms 是层间气泡」 | 是**写通道 DDR 等待** | [ink/GAP_11MS_RESOLVED.md](ink/GAP_11MS_RESOLVED.md) |
| **「ch16 通道数是失败原因」** | **训练配方用错了**（5 个约束缺失） | [CUR_MODEL.md](CUR_MODEL.md) 第三节 |

---

## 五、方法论教训

1. **性能优化必须上板验证** —— 仿真只能验「功能逻辑」，不能验「时序/仲裁行为」
2. **聚合指标满足 ≠ 行为正确** —— 必须配对结构性/差分检查
3. **参数传播要在测试台里验证** —— `-Pstyle_network.BURST_MAX` 不会传到 tb 的实例
4. **训练配方以成功案例为基准** —— 不能照抄另一个失败案例的配方
5. **文件写入要验证读回** —— 本环境曾出现写入被静默回滚（需用 PowerShell 原生 IO）
6. **编译器路径要确认** —— 固件编译目标是 `demo/software/firmware/`，不是新架构目录

---

## 六、清理历史

2026-10-22 执行了报告整理（**0 删除**）：
- 归档 **54** 个已结案报告到 `archive/`（5 个分类）
- `reports/ink` 从 62 → **21** 个当前有效报告
- 新增本 INDEX + 3 个 CUR 汇总
- 详见 [CLEANUP_PLAN.md](CLEANUP_PLAN.md)
