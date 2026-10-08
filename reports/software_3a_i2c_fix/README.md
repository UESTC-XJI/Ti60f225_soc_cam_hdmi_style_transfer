# 软件 AE/AWB 固件：Sapphire I²C ACK 修复

2026-10-09。只修改固件，配套 FPGA 仍为 `../software_3a/software_3a.bit`；不需要重新综合或烧录 FPGA。下载本目录 `soc_video_app.elf`，或当前源码构建的 `software/firmware/build/soc_video_app.elf`。旧 `reports/software_3a/soc_video_app.elf` 保留用于回归复现，不再推荐下载。

## 当前实板状态

用户加载 ACK/RECOVER 修复后确认相机初始化成功；COM4 实测 RAW=30、RESIZE=30、DISP=60、DROP=0、ERR=0。此时 3A 首次曝光确认报 BUS_ERROR。继续核对用户提供的 SC431HAI V1.1 手册，第23页说明 N+2 生效，第29页说明 Group Hold 的 3802[1:0] 帧延迟；最新固件将曝光读回延后至两路计数都前进 3+delay 帧后确认，并分别记录写错误/读错误/值不匹配/等待超时。

最新 ELF 的实板测试遇到另一项残留状态：反复重新加载 ELF 后 RAW=12～13、RESIZE=0、DROP=1、3A state=7。gearbox/resize 的 fault 为硬件锁存，CPU reset 不能清除。需要重新配置现有 software_3a.bit，再加载本目录最新 ELF，才能继续确认 AE/AWB。尚未宣称最新 AE/AWB 已实板工作。

## 原因与修复

用户已下载统一 APB 版本并进入 main 主循环，但 HDMI 始终显示彩条。板上读取 VERSION=0x10000、CAPS=0x1ff、VIDEO_READY=0、RAW/RESIZE=0、DISP=60；DDR 错误为0，摄像头初始化/恢复持续失败。

Sapphire RX_ACK.VALID 在读取 RX_ACK 时清除；写 LISTEN、STOP 均不清除它。旧驱动在读数据时继续监听最终的 master NACK，又等待下一字节 TX_ACK 清除后才读取 RX_ACK，导致残留 VALID 对 ACK 通道施加背压，初始化停滞。修复在每个发送字节之前 drain RX_ACK，并在最终数据读之前关闭 ACK 监听。

增加初始化/重试前的有界 DROP/RECOVER，排除上一次失败或调试暂停遗留的总线状态。RECOVER 已经发送 STOP；不在 idle 再次请求 STOP。最初调试修复版本曾多发 STOP，实板仍失败，已在本目录最终版本中修正。若恢复超时、被丢弃或 SDA/SCL 仍未释放，返回 -4，不虚报初始化成功。

曝光以 pending_exposure 记录，只有帧等待完成、读回字段（含保留位）一致后才更新 exposure/ae_updates。读取实际 3802[1:0]，不改 VTS/PLL/传感器 gain；2秒无法确认则停用控制。UART 增加 AE/AWB 更新次数、code/req/rb；code=1 写入路径总线失败、2 确认读总线失败、3 确认数值不符、4 等待超时。未验证的曝光不会成为软件确认值。

## 验证

- `tools/test_sapphire_i2c_ack.py`：提取原样的 BmbI2cCtrl/I2cSlave/BufferCC_20，连接按位 I²C 从机，通过真实 BMB 寄存器总线模拟。复现旧路径残留 master NACK → 下一次 TX_ACK 阻塞；读取 ACK 后恢复，固定路径连续读出 CD/6B；确认 idle STOP 一直 pending、RECOVER 自带 STOP。
- 实际 RV32 ELF 启动：normal、stale_ack、bus_recover、ID 重试、OSD 无 ACK、DDR 损坏、timer 回绕、trap 全部 PASS；全程没有 ACK 背压停滞。
- 实际 RV32 AE/AWB：连续 ID/VTS/曝光读写、Group Hold/readback、故障注入、控制协调与完整 main 全部 PASS；新增 RECOVER timeout/dropped/恢复后 SDA 仍低的有界失败，以及 3802 延迟0～3帧时旧读回不误报/延迟确认/确认读失败/超时测试。
- 保存的原始 ELF 在改正读后清除/背压语义的模型中复现 ACK stall，VIDEO_READY 始终为0。
- 固件驱动协议与 IDE/OpenOCD 配置检查 PASS。

text=11104、data=4、BSS=512，BIN=11108字节。文件与关键源码 SHA256 见 `manifest.json`。旧 bitstream 与所有原始 release 文件未覆盖。最新 ELF 的实板结果待复查；曝光/颜色效果不能由模型通过推断。

## 调试注意

native VexRiscv 的 GP 名称是 `x3`，不是 `gp`。vendor OpenOCD 的目标内存读取要求 HALTED，运行时读取会触发断言。避免同时使用 IDE GDB 与外部调试脚本改变目标运行状态；优先读 UART，独立探针先 halt、读取后 resume，不 reset 或 load。
