# 显示紧急读通道保留版

使用本目录 bit 与诊断 ELF 配套下载。显示急需数据时禁止在拆包间隙插入新的 CNN 读突发；非紧急时恢复公平仲裁。网络/权重不变。

编译、时序和 RTL 回归均通过，数值见 manifest.json。实板结果见 hardware/README.md：用户确认已不再闪烁，约 93 秒内仍有 16 次欠载事件，NN 约 9～10 fps。

JTAG 配置 FPGA 后等待 DDR 校准，CPU reset halt → load ELF → 设置 _start → 显式 resume。不包含 Flash 自启动镜像。

完整构建报告及源文件原始字节副本见 `../../../docs/style_display_deadline_results/README.md`；manifest 的源文件哈希记录构建主机字节，`published_build_evidence` 给出对应 GitHub 存档路径。
