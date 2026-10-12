# 显示闪烁修复版实板结果

2026-10-12，北京时间。用户确认新版本 **“已不再闪烁”**。

## 结果

新 bit 已配置，配套诊断 ELF 已下载并 resume。DDR scratch、INT8 RGB 自检通过，摄像头 CD6B 初始化成功。真实相机、CNN、HDMI、CPU 同时运行。

排除启动后前三秒，连续 UART 采样从 21:22:53.358 到 21:24:26.039，共 92.688 秒：

| 项目 | 结果 |
| --- | --- |
| UF 增量 | 16 个 underflow 上升沿事件 |
| UF 事件率 | 0.173 次/秒 |
| 之前诊断版正常负载 UF 事件率 | 3458.125 次/秒（86.579 秒窗口） |
| NN | 9～10 fps，日志整数样本平均 9.859 |
| CAP | 9～11 fps，日志整数样本平均 9.859 |
| DISP | 60 Hz |
| 最近单次推理 MS | 89～98 ms，样本均值 93.261 ms |
| MONET ERR | 0 |
| CSI / DME / IERR / AXI | 始终全部 0 |
| 显示读流量 | 约 147.462 MB/s |
| DDROP | 日志间隔内 19～21（约 1.018 秒/间隔） |

UF 是同步到 core 域的显示欠载上升沿计数，不是黑帧数或缺失像素数。新版本仍有少量偶发欠载，FAULT 最终为 4，所以不宣称绝对零欠载。用户的肉眼验证确认持续可见闪烁已消失。NN 吞吐低于原诊断版的约 14～15 fps；这是优先保证显示期限的代价，不能报告为原吞吐下的零成本修复。

## 最终寄存器

CPU 位于 main 服务循环，VIDEO_READY=1，RAW/legacy resize=30/30 fps，PLL/DDR校准/复位状态 0x1f。最终快照 UF=16；捕获1039、丢帧1871、推理1034、显示帧ID1033、显示帧累计7451。

DDR/camera/OSD/style/selftest 软件错误均为0，trap cause/pc/value 均为0。stream_enable=16，profiler freeze=0。快照后显式 resume 和 detach，本次 OpenOCD/UART 采集已退出；COM4 验证仍在线且已释放，开发板保持新版本运行。

## 产物与实现

- Bit：`../ti60f225_oob.bit`，SHA256 `254448D2FEEAA30AEAC726FDD933C8C03D84D8B9B5661CA2C20D9C4975E6B308`。
- ELF：`../soc_video_app.elf`，SHA256 `3F8325DEC3710CC9714BE51A62C61220D3F6F840C5107F4D45ADCD9DAB3800F2`。
- 显示 urgent 覆盖 CNN 三次公平上限；显示 reader 拆包、下一次 AR 尚未提出时保留读通道。当前已接受的突发完整结束。
- urgent 仅限有行任务或请求排队，避免空白期空 FIFO 阻止 CNN；低水位提高到384。外层 CPU/video 仲裁保持默认。
- 网络、权重和模型输出算法保持相同，本次使用原诊断 ELF 读取实际计数。
- JTAG 1 MHz，器件ID 0x10660A79；CPU reset/halt 后加载44624字节，到达main后显式resume。

## 编译和仿真

Efinity map/interface/pnr/pgm 全部通过，最终setup/hold关系均无负裕量，CDC报告无Synchronizer警告。

| 项目 | 结果 |
| --- | --- |
| XLR | 57870 / 60800 |
| RAM | 256 / 256 |
| DSP | 140 / 160 |
| CNN setup slack | +0.611 ns |
| 100 MHz setup slack | +2.283 ns |
| 最小报告 hold slack | +0.026 ns |

仲裁测试覆盖紧急80个连续授权、拆包间隙保留、解除urgent后的公平性和ID。持续CNN读＋模拟返回延迟的一整帧显示测试：原策略/仅取消上限均发生欠载，通道保留版614400像素全部正确且欠载0。集成640×48网络输出逐字匹配整数oracle、307200采集像素一致、显示欠载0，1662139个CNN周期。行为DDR回归不作为物理DDR的精确延迟证明。

详见 `docs/DISPLAY_DEADLINE_FIX.md`、发布manifest、`reports/style_demo/display_deadline/` 和 `reports/style_demo/ddr_optimization/adaptive_reserve/`。

## 原始记录

`programmer.log`、`load.log`、`openocd.log`、`uart_COM4.log`、`uart_timestamped.jsonl`、`uart_summary.json`、`snapshot_1.log`、`snapshot_final.log`。`analyze_uart.py` 可复算UART摘要。UART时间为主机接收时间，调度/串口缓冲会引入误差。

配置为易失JTAG与DDR固件下载，未写入Flash自启动镜像。
