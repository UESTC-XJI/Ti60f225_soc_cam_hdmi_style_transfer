# 显示读优先版本实板下载记录

日期：2026-10-12。用户授权连接开发板后烧录 FPGA 并下载程序。

## 下载结果

- FPGA：`../release_display_priority/ti60f225_oob.bit`，SHA256 `17D6AD09DCD45E3F842F5C9A384AE7124D7D18E2E135A24A0175FF439F71EB77`。
- 固件：`../release_display_priority/soc_video_app.elf`，SHA256 `C70B8224DABB7BADDF9B3DFA1B3E223847B33486436F1CDAA416F5EAFFE8446B`。
- 本次 USB 地址：`ftdi://0x0403:0x6011:0:1/1`。文档中的旧地址未匹配，未执行配置；重新枚举后使用实际地址成功配置。
- JTAG 1 MHz，器件 ID `0x10660A79`，Programmer 明确报告完成。
- OpenOCD 使用端口 23333 / 26666 / 24444。下载前 DDR 校准和各复位释放状态 `0xf8100160 = 0x1f`。
- CPU `reset halt` 后加载 43704 字节，设置 `_start`，成功到达 `main`，SP `0x20000`。
- 本机 native VexRiscv 的 GDB `detach` 不自动恢复 main 断点后的运行；使用 `monitor resume` 后启动正常。后续所有快照均显式 resume 后 detach。

## 实板结果

COM4，115200 8N1，启动日志包含：

```text
SOC VIDEO boot
DDR scratch PASS
STYLE INT8 RGB self-test PASS; MONET VGA
Camera CD6B initialized
MONET VGA
Software AE/AWB enabled; RAW8 stats, fixed VTS, manual lift
```

连续 UART 样本显示 CAP/NN 约 6～7 fps、DISP 60、MS 122～132、ERR 0。显示优先仲裁降低了推理吞吐；用户先前旧版反馈约 11 fps / 83 ms。

两个运行中快照相隔约 30 秒（显示帧计数增加 1805，60 Hz）：

| 项目 | 快照 1 | 快照 2 |
| --- | ---: | ---: |
| 显示欠载 `0xf810014c` | 0 | 0 |
| 故障锁存 `0xf8100140` | 0 | 0 |
| 外层 AXI 错误 `0xf8100148` | 0 | 0 |
| CSI 错误 `0xf810015c` | 0 | 0 |
| VIDEO_READY | 1 | 1 |
| RAW / legacy resize fps | 30 / 30 | 30 / 30 |
| 显示帧累计 | 7738 | 9543 |
| Style capture 累计 | 201 | 434 |
| Style drop 累计 | 558 | 1227 |
| Style inferred 累计 | 196 | 429 |
| 推理 / 显示 DMA / 内层 AXI 错误 | 0 / 0 / 0 | 0 / 0 / 0 |
| app_metrics_updates | 25 | 55 |
| DDR / camera / OSD / style / selftest 软件错误 | 全部 0 | 全部 0 |
| trap cause / pc / value | 全部 0 | 全部 0 |

CPU 两次均位于 main 正常服务循环。DROP 持续增长属于输入约 30 fps、推理约 7 fps 时的队列丢帧，不能单独解释闪烁。

快照完成后恢复 CPU，并关闭本次 OpenOCD、串口采集，释放 JTAG/串口，保留开发板运行。这里是 JTAG 易失配置和 DDR 固件下载，未写入上电自启动 Flash 镜像。

寄存器采样期间没有显示欠载；屏幕实际是否仍有闪烁需要用户观察，不能仅凭计数宣称所有显示问题已解决。

证据：`programmer.log`、`load.log`、`openocd.log`、`uart_COM4.log`、`snapshot_1.log`、`snapshot_2.log`。
