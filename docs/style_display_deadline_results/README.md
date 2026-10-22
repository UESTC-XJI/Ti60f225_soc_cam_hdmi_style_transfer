# 显示期限修复的编译证据

`efinity/` 保存最终通道保留版的时序、资源、CDC、布线和 bit 生成报告；完整构建日志见 `../../reports/style_demo/display_deadline/build_reserve.log`。

`build_inputs/` 保存 manifest 所列 RTL/XML/SDC 及诊断固件源码在构建主机上的原始字节，便于复核 SHA256。项目源码的换行可能随 Git 配置变化；发布 manifest 的 `published_build_evidence` 指向这些保留原字节的副本。副本用于审计，项目实际编译源仍在根目录 RTL/软件路径。

当前 bit/ELF、实板结果及校验值见 `../../reports/style_demo/release_display_deadline/`；单测/争用日志见 `../../reports/style_demo/display_deadline/`，集成逐层验证见 `../../reports/style_demo/ddr_optimization/adaptive_reserve/`。
