# 2026-10-12 再次烧录诊断版

用户恢复连接后授权再次烧录。使用 DDR 优化版 `release_ddr_opt/ti60f225_oob.bit` 与 `flicker_diagnostics/soc_video_app.elf`。

- Bit SHA256：9F3749F6C54E969E71CA34E63FB922FB1F696E140C234121D434402C28E5A955。
- ELF SHA256：3F8325DEC3710CC9714BE51A62C61220D3F6F840C5107F4D45ADCD9DAB3800F2。
- 实际 FTDI 地址 `ftdi://0x0403:0x6011:0:1/1`，JTAG 1 MHz，ID 0x10660A79，Programmer 明确报告完成。
- DDR 校准/复位状态 0x1f；CPU reset halt 后下载 44624 字节 ELF，到达 main 后显式 resume 并 detach。
- 北京时间 20:51:08，DDR scratch PASS、STYLE INT8 RGB self-test PASS；Camera CD6B initialized。
- 稳态 CAP/NN 14～15、DISP60、MS65～66、ERR0。诊断版仍复现显示欠载：20:51:21.716 UF44464、DUF3202、FAULT4；CSI/DME/IERR/AXI 全为0。本次重烧未修改或修复 RTL。
- 正常退出本次 OpenOCD 与 UART 采集，释放 JTAG/串口，CPU 已恢复运行。

完整日志见 programmer.log、load.log、openocd.log、uart_COM4.log、uart_timestamped.jsonl。本次为 JTAG 易失配置与 DDR 固件下载，未写入 Flash 自启动镜像。
