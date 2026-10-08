# IDE GDB error 138 排查记录

本次只排查主机连接；未访问目标寄存器、reset/halt、烧录 bitstream 或下载 ELF。

## 地址复现与修正

使用 `C:/Efinity/efinity-riscv-ide-2026.1/toolchain/bin/riscv-none-elf-gdb.exe`，每次启动独立 IPv4 loopback TCP 服务，模拟最小 RSP 协议（RV32、33 个零值寄存器、线程 1、停止状态 T05）。没有连接 OpenOCD 或板卡。GDB 使用 `--nx --batch`，执行 `set arch riscv:rv32`、`set tcp connect-timeout 2`、`target remote <host>:<临时端口>`、`detach`。

| 主机地址 | GDB 退出码 | RSP 请求数 | 结果 |
| --- | --- | --- | --- |
| localhost | 1 | 0 | could not connect (error 138): 系统试图将驱动器合并到合并驱动器上的目录。 |
| 127.0.0.1 | 0 | 14 | 0x00000000 in ?? (); Remote target detached |

`localhost` DNS 返回 `::1` 和 `127.0.0.1`。不能仅凭上述结果断定 GDB 内部的具体失败路径，但固定 IPv4 地址已通过真实 GDB 的本机协议验证。共享 `software/firmware/soc_video_app_ti.launch` 的 `org.eclipse.cdt.debug.gdbjtag.core.ipAddress` 已改为 `127.0.0.1`。

## 旧 OpenOCD 残留

| PID | 启动时间 | IPv4 loopback 监听端口 |
| --- | --- | --- |
| 6760 | 2026-10-08 18:53:35 | 3333 / 4444 / 6666 |
| 33136 | 2026-10-08 21:33:10 | 13333 / 14444 / 16666 |

两个进程均使用本项目 `soc_video.cfg`，早于当前 IDE PID 30088（23:49:05）。IDE workspace `.metadata/.log` 记录重复启动以及 23:51/23:52 的相同连接错误。13333 的 IPv4 TCP 连接超时，16666 Tcl `version` 查询超时；默认端口的 Tcl 连接也超时。

Windows CIM/tasklist 仍列出两个进程，每个剩余 1 个等待线程；Get-Process 无法取得进程，taskkill /F 报“没有运行的实例”，监听端口仍保留。已根据命令行核实并结束其旧 `starter.exe` 父启动器 PID 35204/12256，未结束当前 IDE。FTDI 0403:6011 的 MI_01 接口仍显示 OK；在线状态不能证明旧会话可用。

当前终端无管理员 token，未尝试重启设备或更改驱动。用户确认已重新拔插 JTAG USB 后复查：FTDI MI_01 在线且状态 OK，但 PID 6760/33136 及全部六个旧监听端口仍保留。恢复步骤升级为保存工作后重启 Windows，不能仅重开 IDE。尚未验证实板重新连接成功。

## 配置检查

`python tools/check_firmware_config.py`：PASS。检查共享 launch、可执行文件/ELF 路径以及原始 OpenOCD 配置的四种路径形式；设置 SOC_CONFIG_CHECK 跳过硬件 init/halt。未重编或修改配套 bitstream/ELF。
