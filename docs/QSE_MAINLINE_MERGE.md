# B 主线 QSE 外设合并（2026-10-30）

本次以 integrated_20261029 为主线，合入 A 的按钮与网页功能；保持 B 的原生 320×240 风格结果、UART0 和旋钮定义。

## 接线与操作

| 功能 | FPGA GPIO | 电气/行为 |
|---|---|---|
| KEY0 | GPIOL_11 | 高电平按下，弱下拉；固件消抖 20 ms；开关 FPS 叠加 |
| KEY1 | GPIOL_09 | 高电平按下，弱下拉；固件消抖 20 ms；切换对比/单风格显示 |
| SW1 | GPIOL_04 | 弱上拉，保留 B 原始电平定义 |
| SW2 | GPIOL_10 | 弱上拉，保留 B 原始电平定义 |
| BLE RX | GPIOL_06 | 模块 TX → FPGA RX，弱上拉 |
| BLE TX | GPIOR_13 | FPGA TX → 模块 RX |

3.3 V LVCMOS。蓝牙为 UART0，128000 8N1，默认发送限速 1500 B/s。Python 构建与 shell 构建均定义 BLE_SILENT_UART，关闭其他调试输出。

已移除原 GPIOR_22/panel_key 的顶层输入、引脚约束和 style_key_toggle 实例。该 GPIO 不再控制显示。style_key_toggle.sv 保留为未引用的历史模块，不在活动工程源文件表中。
默认 FPS 开、对比模式开。按键按住不重复触发，松开经消抖后下次按下才切换；开机已按下的按键须先松开。
KEY1/VIEW 复用 B 已有的帧首锁存与显示几何；单风格显示保持 B 的尺寸和缩放方式。KEY0/OSD 在视频帧边界更新 FPS 开关，不恢复已移除的文字 OSD。

## 旋钮与命令

| 原始 {SW2,SW1} / KNOB 数值 | 风格 |
|---|---|
| 00 / 0 | G3 mosaic（style 2，5 档） |
| 01 / 1 | G1 starry 星空（style 0，5 档） |
| 10 / 2 | G2 candy 糖果（style 1，5 档） |
| 11 / 3 | G4 feathers 羽毛（style 3，5 档） |

实体旋钮在 main.c 保持原路径（两级同步，20 ms 消抖，约 1 kHz 服务）。蓝牙选档或 SLOT 选择后，下次实体档位发生稳定变化时接管。

- `VIEW` 切换；`VIEW,0` 单风格；`VIEW,1` 对比。
- `OSD` 切换；`OSD,0/1` 关闭/打开 FPS。
- `KNOB,0..3` 按上表选择，回 KNOB、SLOT、BANK。
- `SLOT` 查询；`SLOT,0..3` 选择风格（0=starry，1=candy，2=mosaic，3=feathers），回 SLOT/BANK/TIER；每个风格 5 档，用 `TIER,<style>,<0..4>` 调整，默认第 3 档。
- `STATE` 返回 KNOB、SLOT、BANK、OSD、VIEW、RATE。KNOB 为上次实体/远程旋钮值，SLOT/BANK 为实际活动权重；直接 SLOT 选 BANK 不伪造旋钮位置。
- `RATE` 查询；`RATE,n` 设置限速，范围 200..12800 B/s，默认 1500。
- `SNAP[,320[,q[,win]]]` 仅支持原生 320×240；质量 1..100，默认 60；窗口 1..8，默认 4。160/640 返回 IMG,ERR,ARG。
- `ACK,n`、`NAK,n`、`ABORT` 保留原图传协议；未知行原样回显。

`SLOT` 是权重 BANK 编号，与图传内部的 DDR 帧缓冲 slot 不同。切换失败时报告实际活动 BANK。

## 网页

tools/ble_web/index.html 合入 A 的设备绑定/重连/解除绑定、视图/OSD 控制、拍摄、连续拍摄、图库、保存和文本收发；纠正为 B 的 KNOB 标签，添加 BANK/SLOT 解析、BANK 选择、STATE 按钮。只提供 320×240，默认速率 1500 B/s。

本机可运行 `python -m http.server 8000 --bind 127.0.0.1 --directory tools/ble_web`，用 Chrome/Edge 打开 http://localhost:8000/。

## 验证与构建

- `python tools/build_firmware.py`：编译与无未定义符号链接。
- `python tools/test_qse_mainline.py`：实际 RV32 ELF，UART0、按键抖动/长按/释放、命令、BANK/旋钮映射、速率、320×240 JPEG 和 ACK 传输。依赖 unicorn/pyelftools（可安装到 work/peripheral_test_deps）、Pillow。
- `node tools/ble_web/test_mainline_ui.js`：执行实际网页脚本，状态/标签/命令、实际 RV32 图传回放、丢包/坏包恢复。
- `python tools/test_qse_mainline_rtl.py` / `tests/qse_mainline_ui_tb.sv`：APB 新寄存器、非法写、原旋钮位不变、FPS 帧边界开关及像素/同步直通。
- `tests/tb_disp_toggle.sv`：B 原有帧中切换显示回归。

新增 APB：0xF8100130 bit0=FPS enable、bit1=compare，复位 3；0xF8100134 bit0=KEY0、bit1=KEY1（已两级同步）。旋钮仍在 0xF8100054 bit[3:2]。

完整 FPGA 编译在 work/peripheral_merge_fpga 输出，旧 outflow 位流未覆盖。只有固件更新不足以接入新增 GPIO，必须使用本次构建的匹配位流。此轮不自动烧写硬件。

软件、RTL 验证已通过：实际 RV32 按键/命令/BANK/JPEG/ACK 测试、网页状态与图传丢包恢复、APB/FPS 控制、6 帧对比/单风格切换（每帧 uf=0、bad=0）。FPGA 最终状态见随包 validation.json。

最终 FPGA 构建：map / interface / pnr / bitstream 全 PASS。所有已分析 setup/hold 时钟关系裕量为正；最小 setup +0.235 ns，最小 hold +0.026 ns；vid_clk_dvi2 setup +0.260 ns，core_clk setup +2.544 ns。资源 XLR 59415/60800、RAM 202/256、DSP 147/160。尚未上板验证。

产物：deliverable/qse_mainline_merge_20261030；其中 ti60f225_oob.bit 与 soc_video_app.elf 配套。源码已直接修改在 B 主线工程中，旧 outflow 保留。
