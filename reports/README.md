# 项目目录与产出管理

> **想查报告结论请先看 [INDEX.md](INDEX.md)** —— 那里有当前结论（CUR_PERF / CUR_MODEL / CUR_BOARD）和按主题的导航。
> 本文件只说明「哪些目录进 Git」。最近整理（2026-10-22）：54 个历史报告已归档到 `archive/`，见 [CLEANUP_PLAN.md](CLEANUP_PLAN.md)。

| 目录 / 文件 | 用途 | Git 管理方式 |
| --- | --- | --- |
| `rtl/`、`ip/`、`soc/` | RTL、IP 设置、生成后参与编译的 SoC RTL 与 ROM 初始化数据 | 保留版本管理 |
| `software/` | 固件源码、BSP、链接脚本、IDE 和 OpenOCD 配置 | 保留版本管理；忽略 `build/`、`Debug/`、`Release/` |
| `tests/`、`tools/` | 仿真输入、回归及构建脚本、配置校验清单 | 保留版本管理 |
| `docs/`、根目录 Markdown | 设计、交接、运行和烧录说明 | 保留版本管理 |
| 根目录工程 XML、SDC、调试配置 | Efinity 构建与调试输入 | 保留版本管理 |
| `outflow/`、`outflow_*/` | Efinity 编译输出；本次清理构建位于 `outflow_cleanup/` | 忽略 |
| `work/`、`work_syn/`、`work_pnr/`、`work_dbg/` | 临时快照、仿真程序、综合/布局布线/调试中间文件 | 忽略 |
| `reports/<版本>/` | 正式交付文件、构建报告与验证结果 | 保留 bit、ELF、Markdown、`manifest.json` 和 `build_project.xml`；忽略日志及其他中间产出 |
| `reports/hardware_debug/` | 串口/JTAG 日志、目标内存读回和人工排障记录 | 忽略产出；保留 Markdown 记录 |
| `reports/simulation/`、`reports/baseline/` | 可再生成的仿真结果、完整历史源码及构建备份 | 整目录忽略 |

当前推荐配套烧录文件为 `reports/soc_cleanup/soc_cleanup.bit` 和
`reports/soc_cleanup/soc_video_app.elf`，随源码一起纳入 Git。
`outflow_cleanup/ti60f225_oob.bit` 与发布 bit 完全相同；
`software/firmware/build/soc_video_app.elf` 与发布 ELF 完全相同。
编译工作目录继续忽略，版本目录中的 bit/ELF 用于直接下载和复现对应版本。

不要全局忽略 `*.bin`、`*.hex`、`*.mem`、XML 或 `netlist/`：项目中的
SoC/IP 包含实际编译所需的初始化数据和生成 RTL。产出规则按目录限定。

`.gitignore` 仅影响未跟踪文件。此前已经提交的历史报告和产物仍保留在
Git 索引及历史中；新增忽略规则不会删除本地文件。
