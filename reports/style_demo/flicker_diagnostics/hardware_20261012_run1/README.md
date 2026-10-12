# 2026-10-12 显示闪烁实板诊断结果

## 结论

约 14～15 fps 的 DDR 优化版在实板上发生大量显示欠载。正常采集、推理并发时欠载持续增长；关闭采集和新推理、保留最后一帧显示时停止增长；重新开启并发负载后再次增长。用户同时确认 HDMI 肉眼可见左右画面共同出现黑块。

已确认的故障环节是公共显示供数路径未在像素期限内提供匹配数据。当前证据支持并发 DDR 访问下的显示实时性不足；不能仅凭这些计数单独判定三突发公平上限、物理 DDR 返回抖动、像素缓存余量或过期行积压中哪一项是唯一根因。

## 本次下载

按 `docs/DISPLAY_FLICKER_DIAGNOSTICS.md` 使用以下配套产物，没有烧录撤回的提前四行实验。

- FPGA：`reports/style_demo/release_ddr_opt/ti60f225_oob.bit`。
- Bit SHA256：`9F3749F6C54E969E71CA34E63FB922FB1F696E140C234121D434402C28E5A955`。
- ELF：`reports/style_demo/flicker_diagnostics/soc_video_app.elf`。
- ELF SHA256：`3F8325DEC3710CC9714BE51A62C61220D3F6F840C5107F4D45ADCD9DAB3800F2`。
- JTAG：1 MHz，器件 ID `0x10660A79`，Programmer 明确报告成功。
- 下载前 DDR 校准/PLL/复位状态 `0xf8100160 = 0x1f`。
- CPU reset/halt 后加载 44624 字节，设置 `_start`，到达 main 后显式 resume。
- 启动日志：DDR scratch PASS、STYLE INT8 RGB self-test PASS、Camera CD6B initialized。
- 原 IDE 的当前工程 OpenOCD/GDB 会话因占用 JTAG 已结束；保留 IDE 窗口与用户代码/配置改动。

## 三阶段受控对照

时间均为北京时间，排除启动和切换后的短暂过渡。UF 是同步到 core 域的 underflow 上升沿事件数，不能解释成坏帧数或缺失像素数。

| 阶段 | 采样时间 | 时长 | UF 增量 | UF 事件/秒 | CAP/NN | DISP |
| --- | --- | ---: | ---: | ---: | --- | ---: |
| 正常采集＋推理＋显示 | 20:38:25.716～20:39:52.301 | 86.579 s | 299401 | 3458.125 | 14～15 | 60 |
| 关闭采集/新推理，保持已完成帧显示 | 20:39:55.344～20:40:45.067 | 49.719 s | 0 | 0 | 0 | 60 |
| 恢复采集＋推理＋显示 | 20:40:48.106～20:41:17.675 | 29.563 s | 102514 | 3467.645 | 14～15 | 60 |

关闭写 `0xf8100204 = 0`，恢复写 `0xf8100204 = 16`。RTL 中这只禁止新采集和新推理，不清除 display_valid，不重置显示、DDR、已完成帧或欠载计数；在途任务/抓帧自行结束。关闭阶段 UF 恒定在 314678，FAULT=4 的历史锁存仍保留；显示帧计数继续推进，显示刷新仍为 60 Hz。

关闭阶段 DDR profiler 因 stream_enable=0 停止计数，所以其 T/RB/DRB=0 **不代表显示没有读取 DDR**，不能用它估算该阶段带宽。

正常阶段 MONET 的 MS 为 65～66，ERR=0；VIDEO 的 CSI/DME/IERR/AXI 全部为 0，FAULT 始终为 4（显示欠载 bit2）。DDROP 为每个日志窗口 14～16，约 1.018 s/窗口；这是输入快于处理时的队列丢帧，不能作为显示欠载数。

## DDR 数据及其含义

正常阶段平均显示读流量约 147.154 MB/s、CNN 读流量约 251.310 MB/s，均按 beat×16 和 profiler 的 100 MHz 窗口换算，只统计这些读通道。两幅 VGA 画面在 60 Hz 下理论读需求为 147.456 MB/s。平均读量接近需求仍不能保证每行/每像素及时到达。

恢复重烧后读取的一组原始软件快照（完整数据在 `recovery/snapshot_running.log`）：

```text
T    101844689
AR     9413269
DOWN     64118
RGAP  19562167
RBP     267395
DBP          0
AW      506113
W      4089136
B       460295
IDLE        32
RB    15940320
DRB    9353344
```

- CNN 地址仲裁等待 AR/T 约 9.24%；CNN 返回间隙 RGAP/T 约 19.21%。这些是 CNN 侧统计，不能当作显示最长等待时间。
- 显示接收反压 DBP 原始值为 0，说明这组窗口内新增 beat 缓冲没有以拒收 RVALID 的方式占住共享返回通道。
- RBP、DOWN、AW、B 虽然 UART 显示 0%，原始值非零但小于 1%；UART 百分比使用整数截断。
- 网络读阶段快照 4992511 个 148.5 MHz 周期（约 33.62 ms），core busy 4725739 周期（约 31.82 ms）。core busy 含输出背压，不是纯乘加时间。
- DDR scratch/INT8 自检通过，运行中 DDR/camera/OSD/style/selftest 软件错误均为 0，trap cause/pc/value 均为 0，VIDEO_READY=1，RAW/legacy resize 均为 30 fps。

## 源码对应与下一步

1. `rtl/style/style_display.sv:18` 每行只提前一行请求；像素 FIFO 为 512 项（同文件第 71 行），约覆盖 6.90 us 的连续活动像素，少于一个 1280 像素显示行。32-beat 缓冲提供额外突发存储，但不等于整行缓存。
2. `rtl/style/style_display.sv:42` 在低水位、行任务超过 1600 个 core 周期或请求排队时提出 urgent。
3. `rtl/soc_integration/axi_shared_ddr_2m.sv:43` 的仲裁在 CNN 请求持续等待且显示已绕过三次后，即使 urgent 仍授权 CNN。已经在途的突发也不能被抢占。应优先验证 urgent 是否需要硬期限覆盖公平限额，以及低水位/行年龄阈值是否留足最坏等待余量；目前没有测到该限额具体造成了多少欠载。
4. `rtl/style/style_display.sv:96` 只丢弃旧 epoch 的行请求；同 epoch 中已经过期的行仍会读完整左右图。`pixel_ready` 会丢弃迟到像素，但不会取消源端过期行 DMA，可能使恢复期间继续浪费读带宽。
5. 下一轮用持续 30 fps 采集、外层 CPU 竞争和突发 DDR 延迟复现，补充显示 AR 最长等待、行期限错过、过期行跳过及 FIFO 最低水位的测量。先验证紧急授权和过期任务处理，再评估缓存容量；不能把平均带宽或简单提前请求作为修复证明。

当前 RAM 已用满，增加缓存需要重新预算和验证。已有 6～7 fps 固定显示优先版曾测得 UF=0，可作为后续吞吐/稳定性对照，但旧测量不是本次新版本的修复验收。

## USB 中断及最终板卡状态

20:41:17 开始尝试仅暂停 CPU、让 FPGA 采集/推理/显示继续运行，以进一步区分外层 CPU 竞争；随后 USB/JTAG 与串口掉线，末端计数没有读到。**该对照无效，不据此排除 CPU 竞争。**

用户恢复 USB 后，CPU 调试 halt 一度超时；重新烧录同一 bit、重新下载同一诊断 ELF，恢复正常启动。重启后连续日志再次出现欠载，CSI/DME/IERR/AXI 仍为 0，最终 UART 样本 UF=194323、DUF=4555、CAP14、NN15、DISP60、MS66、ERR0。CPU 已 resume、stream_enable=16、profiler freeze=0；本次 OpenOCD 和串口采集均已退出，开发板保留在诊断版运行状态。

收尾时尝试验证串口可重新打开，COM4 已不存在；再次枚举确认板载 FTDI/串口再次离线。上段运行状态是本次调试退出前的已确认状态，无法据此保证再次离线后的供电或当前执行状态。第二次离线发生在 CPU resume 和调试服务正常退出之后，没有留下人为暂停 CPU 的操作。

本次是诊断与测量，尚未修复闪烁。配置采用易失 JTAG、固件位于 DDR，未生成或写入 Flash 自启动镜像。

## 原始证据

- `programmer.log` / `load.log` / `openocd.log`：第一轮配置与下载。
- `uart_COM4.log`：连续原始 UART。
- `uart_timestamped.jsonl`：每行北京时间及主机单调时钟；接收时间存在串口/调度延迟。
- `uart_summary.json`：排除过渡样本后的三阶段统计；`analyze_uart.py` 可复算。
- `disable_stream.log` / `restore_stream.log`：可逆控制写入和硬件计数。
- `snapshot_streaming.log`：正常负载寄存器快照。
- `cpu_halt.log`：未完成的 CPU 对照起点；不能与重烧后的计数相减。
- `recovery/`：USB 恢复后重烧、启动、最终寄存器和 UART 日志；其计数从新配置后的 0 重新累计。
