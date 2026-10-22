# 目录整理说明

> 日期：2026-10-15
> 目的：把根目录的分析产物归档，保留构建必需文件

---

## 为什么不能把所有东西都移走

根目录有 **12 个被 git 追踪的文件必须留在原地**，因为 Efinity 工程以
**根目录相对路径**引用它们：

| 文件 | 引用位置 |
|---|---|
| `debug_top.v` | `ti60f225_cam_hdmi.xml`: `<efx:design_file name="debug_top.v" .../>` |
| `ti60f225_oob.sdc` | `ti60f225_cam_hdmi.xml`: `<efx:sdc_file name="ti60f225_oob.sdc"/>` |
| `debug_profile.wizard.json` | `<efx:param name="profile" value="debug_profile.wizard.json" .../>` |
| `ti60f225_cam_hdmi.xml` | 工程主文件 |
| `ti60f225_oob.peri.xml` | 引脚约束 |
| `MonetStyleDemo.code-workspace` | 工作区定义 |
| `package_settings.xml` | 封装设置 |
| `debug.json` | 调试配置 |
| `Panel_1080p_reg.mem` | 面板寄存器初始化 |
| `yuvpattern_mif.memh` | 测试图案 |
| `.gitattributes` / `.gitignore` | git 配置 |

**移动这些会破坏综合流程。**

其余根目录文件都是分析过程产物（未追踪），可以归档。

---

## 归档后的结构

```
demo/
├── （12 个构建必需文件，保持原位）
├── reports/
│   ├── analysis/                    ← 项目级分析报告（9 篇）
│   │   ├── CYCLEGAN_SOURCE_NOTES.md
│   │   ├── FRAMEWORK_EVALUATION.md
│   │   ├── INT_VS_FP_REPORT.md
│   │   ├── RESOURCE_RECOVERY_ANALYSIS.md
│   │   ├── SIMULATION_METHOD.md
│   │   ├── HDMI.md
│   │   ├── DEPLOYMENT_NOTES.md
│   │   ├── STEP3_HEAD_FEASIBILITY.md
│   │   └── pytorch-CycleGAN-and-pix2pix-阅读笔记.md
│   └── ukiyoe/
│       ├── docs/                    ← 浮世绘专题报告（11 篇）
│       │   ├── UKIYOE_TRAINING_PLAN.md
│       │   ├── UKIYOE_RESULTS.md
│       │   ├── UKIYOE_EFFECT_ASSESSMENT.md
│       │   ├── UKIYOE_VS_OFFICIAL.md
│       │   ├── STYLE_VISIBILITY_ANALYSIS.md
│       │   ├── STROKE_ANALYSIS.md
│       │   ├── TRAINING_IMPROVEMENTS.md
│       │   ├── TRAINING_DIRECTION.md
│       │   ├── V8_TRAINING_LOG.md
│       │   ├── V9_CANDIDATE.md
│       │   └── STAR_STYLE_TRAINING_PLAN.md
│       ├── figures/                 ← 图与数据（9 个）
│       ├── data/  teacher*/  student*/  export*/  comparison/ ...
└── tools/analysis/                  ← 分析脚本（12 个）
```

---

## 脚本移动的注意事项

根目录的 12 个 `_*.py` 脚本都以 `Path(__file__).resolve().parent` 作为 ROOT，
所以**直接移动会让它们找不到 `ml/`、`reports/`、`_data/`**。

移动时需在脚本开头插入向上定位：

```python
# 移动到 tools/analysis/ 之后：仓库根在两级之上
ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
```

**已在移动时自动完成这一步。**

---

## 为什么不放在 `docs/`

`docs/` 是**被追踪的项目文档目录**（162 个文件，含 Efinity 相关的
`RESOURCE_OPTIMIZATION_PLAN.md`、`STYLE_DEMO_IMPLEMENTATION.md` 等）。
把分析过程产物混进去会污染项目文档。

`reports/` 已被 `.gitignore` 规则覆盖：

```
/reports/**/*
!/reports/**/
!/reports/**/*.md          <- .md 文件被显式放行
```

所以放在 `reports/` 下**不会进 git**，符合"这些是过程产物"的定位。
