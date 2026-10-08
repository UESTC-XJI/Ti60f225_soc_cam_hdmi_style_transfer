# 完整 SoC 视频应用与下载

下载文件：`build/soc_video_app.elf`。使用 BSP 实际 UART/I²C/CLINT 驱动，入口 `_start=0x1000`。旧 `work/soc_video_driver*.elf` 是只有摄像头函数入口的历史产物，不用于整机运行；新构建脚本只生成完整应用。

## 应用行为

`start.S` 禁止中断、初始化 GP/SP、设置异常入口、同步 cache、处理数据段并清零 BSS 后进入 `main()`。程序异常时记录 `firmware_trap_cause/pc/value` 并停在 `trap_halt`，供 IDE 观察。

主程序初始化 UART 115200/8N1，在隔离 scratch DDR 前 64 KiB 执行两种地址相关模式的读写测试；初始化 100 kHz Sapphire I²C，等待 20 ms，验证 SC431HAI ID `0xCD6B` 并写入 165 项初始化表，然后提交 `HELLO SOC`。摄像头 ID/init 失败时每秒调用恢复。主循环轮询 CLINT，前次更新完成至少一秒后再次执行 DDR 测试并发布 `FPS/DISP/DROP/ERR`；无需定时器中断。

每次 OSD 更新写满非显示页的 80 个字符，短字符串尾部补空格。COMMIT 等待 ACK 的最长时间为 250 ms，busy 时拒绝继续写页；失败会增加 `app_osd_errors` 并打印日志。正常提交的 UART 内容与字符页一致。`app_ddr_errors/app_camera_errors/app_metrics_updates` 可在 IDE 中查看。

## 构建与仿真

从 Git 工作区根目录运行（当前安装为 Efinity RISC-V IDE 2026.1）：

```powershell
python tools/build_firmware.py
python -m pip install --target work/sim_deps -r tools/firmware_sim_requirements.txt
python tools/test_firmware_runtime.py
python tools/check_firmware_config.py
```

工具链默认 `C:/Efinity/efinity-riscv-ide-2026.1/toolchain/bin`，可用环境变量 `SOC_RISCV_TOOLCHAIN` 覆盖。构建使用 RV32IM/Zicsr/Zifencei、ILP32，附调试符号，输出 ELF/BIN/MAP。BIN 起始地址是 `0x1000`，没有自动添加 Flash boot header。

仿真执行真实 ELF 的 RV32 指令并建模 UART/I²C/CLINT/APB 寄存器；验证启动 GP/SP/BSS/中断配置、正确 ID 初始化、错误 ID 重试、无 ACK 超时、DDR 错误、CLINT 低 32 位回绕及异常记录。Sapphire custom cache 指令作为模型操作处理，未模拟真实 cache、受保护 CPU RTL、DDR 控制器时序或物理 I²C。结果写入 `reports/simulation/firmware_runtime.json`。原 Python driver 协议模型是独立的较弱证据。

## Efinity RISC-V IDE 下载

1. 在 Efinity Programmer 烧录本工程 bitstream，等待 `cal_done`。CPU 释放复位及 ELF 下载都依赖 DDR 校准；将 ELF 从 JTAG 加载到 DDR，不是写入片上 RAM。
2. 断开 Programmer/EDB 的 JTAG 连接，释放板载 FTDI adapter。保留 FPGA 已加载的配置。
3. IDE 中 **File → Import → General → Existing Projects into Workspace**，选择当前工作区的 `software/firmware`，导入 `soc_video_app`。不要勾选 Copy projects into workspace，否则工程的相对 BSP/tools 路径会失效。
4. **Project → Build Project**。工程使用 Python 外部构建脚本，必须让 IDE 能找到 `python`；产物为 `software/firmware/build/soc_video_app.elf`。
5. **Run → Debug Configurations → GDB OpenOCD Debugging**，选择共享配置 `soc_video_app_ti`。若未自动出现，刷新项目，再通过 **File → Import → Run/Debug → Launch Configurations** 导入项目中的 `.launch`。
6. 核对 ELF 为 `build/soc_video_app.elf`，OpenOCD/GDB 来自 2026.1 的安装目录。配置引用 `openocd/soc_video.cfg` 和本项目匹配的 `cpu0.yaml`，采用 native VexRiscv/USER1，FTDI channel 1，JTAG 800 kHz。
7. 点击 **Debug**：halt → 加载 ELF/symbols → 设置 PC 为 `_start` → 在 `main` 临时断点停下。点击 **Resume** 后运行应用。
8. 串口 115200/8N1 查看 `SOC VIDEO boot`、`DDR scratch PASS`、`Camera CD6B initialized`、`HELLO SOC` 和每秒的统计。帧率由 FPGA 寄存器提供，不是固件自造数值。

此 launch 避免下载后的硬复位，以免破坏 DDR 启动状态；重新运行应再次从 `_start` 进入。RAM 下载不提供断电保留；当前 bitstream 内的 boot ROM 不包含这份新应用，上电自动启动需要另做 Flash 镜像。当前只验证 IDE headless 导入/构建及 OpenOCD 配置解析，未连接硬件做真实下载。

## 命令行备用下载

仍在工作区根目录，先在第一个 PowerShell 终端启动：

```powershell
& 'C:/Efinity/efinity-riscv-ide-2026.1/openocd/bin/openocd.exe' -f software/firmware/openocd/soc_video.cfg
```

第二个终端执行：

```powershell
& 'C:/Efinity/efinity-riscv-ide-2026.1/toolchain/bin/riscv-none-elf-gdb.exe' software/firmware/build/soc_video_app.elf -x software/firmware/openocd/download.gdb
```

GDB 将停在 `main`；输入 `continue` 运行。只有用户实际连接板卡时才执行这两个下载命令。
