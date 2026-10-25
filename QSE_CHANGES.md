# QSE 子卡接入与显示交互改动说明

## 1. 范围与交付状态

- 工程：`ti60_style_demo`
- 分支：`qse-extension`
- 改动范围：QSE 管脚、UART1 SoC IP、GPIO 同步、RTL 消抖、旋钮 OSD 标签、显示模式切换。
- 已完成：定向仿真、Efinity 综合、接口生成、布局布线、位流生成及现有固件重新编译。
- 未完成：板上验证；未执行烧录，未创建 Git commit。
- 旋钮仅改变标签，不加载或切换神经网络权重。

当前候选交付：

```text
reports/versions/qse-ui_912aa0564b09/
├── REPORT.md
├── QSE_UI.md
├── manifest.json
├── artifacts/
│   ├── ti60f225_oob.bit
│   ├── soc_video_app.elf
│   └── soc_video_app.bin
├── evidence/
└── inputs/
```

位流 SHA-256：

```text
912aa0564b09c5dea994ebb3c9976d024f01ccdde514d184cb880de9fc895832
```

## 2. 用户可见行为

| 输入 | 功能 | 上电默认 |
|---|---|---|
| 旋钮 SW1、SW2 | 左上角显示当前档位标签 | 同步、消抖后显示实际档位；复位暂为 0 |
| KEY0 | 每次有效按下切换文字 OSD 开／关（HDMI 直方图叠加已删除） | 开启 |
| KEY1 | 每次有效按下切换单幅风格画／原画与风格画对比 | 对比 |

### 2.1 旋钮标签

标签位于有效显示区 `(16,16)`：

| 档位 | 标签 |
|---|---|
| 0 | `0:origin` |
| 1 | `1:style1` |
| 2 | `2:style2` |
| 3 | `3:style3` |

上述名称仅表示旋钮档位。特别是 `0:origin` **不会切换为原画输出**，也不会停止推理或替换权重。实际风格仍使用原有模型。

原有性能统计文字移到 `y=40`，与标签分行显示。固件原有 OSD enable 仍是额外使能条件；固件刷新文字不会覆盖 KEY0 的关闭状态。

### 2.2 画面模式

- **对比模式**：保留左侧原画、右侧风格画，两幅图各为 640×480。
- **单风格模式**：只显示同一张风格结果，保持 640×480，居中放在 1280×720 输出中，其余为黑边；不进行放大或拉伸。
- 单幅有效坐标：`x=320..959`、`y=120..599`，坐标以有效显示区左上角为原点。
- 显示模式在垂直消隐期间锁存，不在有效图像行中途切换。

## 3. 管脚与 SoC 接入

| 顶层端口 | FPGA 资源 | 方向 | 电气设置 |
|---|---|---|---|
| `io_sw1` | `GPIOL_04` | 输入 | 3.3 V LVCMOS，弱上拉，低有效 |
| `io_sw2` | `GPIOL_10` | 输入 | 3.3 V LVCMOS，弱上拉，低有效 |
| `io_key0` | `GPIOL_11` | 输入 | 3.3 V LVCMOS，弱下拉，高有效 |
| `io_key1` | `GPIOL_09` | 输入 | 3.3 V LVCMOS，弱下拉，高有效 |
| `ble_uart_rxd` | `GPIOL_06` | 输入 | 3.3 V LVCMOS，弱上拉，接模块 TX |
| `ble_uart_txd` | `GPIOR_13` | 输出 | 3.3 V LVCMOS，驱动强度 2，接模块 RX |

<img src="/home/goodmann/Downloads/tb_image_share_1792781397317.png" alt="tb_image_share_1792781397317" style="zoom:33%;" />

### 盒子里有两个方形自复位按钮 按方式一接线

通过 Efinity Interface Designer API 设置并保存，而不是猜测 XML 枚举。API 的 `WEAK_PULLDOWN` 保存为 `pull_option="weak pulldown"`。已有 GPIO 配置保持不变。

实际调用 Efinity Sapphire 生成器重新生成 UART1，保留现有 Lite 配置与统一 DDR 时钟配置：

- UART1 FIFO：128。
- UART1 中断号：2。
- 实际生成 BSP 地址：`SYSTEM_UART_1_IO_CTRL = 0xf8011000`；沿用当前工程自定义地址映射，不直接套用原方案中的 GUI 预留值。
- UART0 调试串口及原管脚保持不变。
- GPIO0 读值从常数零改为同步后的 `{~SW2, ~SW1, KEY1, KEY0}`。
- 生成 BSP 先与现有头文件做 diff，再同步 `soc.h`，没有整体覆盖自定义 BSP。

本次未新增 BLE 应用协议、蓝牙业务收发或 C 按键处理。

## 4. RTL 实现

### 4.1 输入同步和消抖

`qse_gpio_sync.sv` 使用两级触发器同步输入，并统一有效极性。该模块分别用于 SoC 时钟域和显示像素时钟域，不能把 SoC 同步结果直接当作像素域同步结果。

`qse_ui_control.sv` 在像素时钟域实现交互：

- 按键连续稳定 1,485,000 个时钟后确认，按标称 74.25 MHz 像素时钟对应 20 ms。
- 按下和释放均消抖；仅确认按下时切换一次，长按不连发。
- 两位旋钮作为一个整体候选值进行稳定判定；候选值任意变化都会重置计数，避免两个不同的未稳定状态累积成一次有效档位。
- SW 输入先按低有效归一化，再将 `{SW2,SW1}` 的格雷码 `00、01、11、10` 解码为 `0、1、2、3`。
- OSD 开关、模式和档位标签只在视频帧边界发布。

实际旋钮起始档位及顺／逆时针顺序尚需对照实物确认。

### 4.2 OSD 标签

复用 `osd_text_double_buffer.sv` 的现有字体和 RGB 流水线，不额外实例化一套字体 ROM。

- 标签字符与原有字符 RAM 读数据分别寄存，再选择送入字体 ROM。
- 字符 RAM 保持独立、无条件的同步读端口，以保留 Efinity BRAM 推断。
- 保持原有 RGB、DE、HS、VS 三周期流水线对齐。
- KEY0 只作用于文字 OSD；HDMI 直方图叠加已在 3A 精简中删除。

首轮实现曾将字符选择条件直接包围 RAM 读操作，导致 RAM 展开为逻辑；最终版本已修正，不应使用该中间构建作为交付。

### 4.3 显示 DMA

`style_display.sv` 增加可选 UI 模式输入，默认参数保持旧模块调用的对比行为。

- 每个行请求携带该帧的显示模式，并通过异步请求 FIFO 进入 DDR 时钟域。
- 对比模式读取原画行和风格结果行；单幅模式只读取风格结果行。
- 单幅模式将图像窗口居中，同时调整期望 X 坐标和过期像素判断。
- 不能只移动窗口而不修改过期像素判断，否则左侧黑边期间的无符号减法下溢会错误丢弃预取像素。
- 原有欠流、DMA 错误统计保持可见，没有通过屏蔽错误改善统计结果。

### 4.4 时序约束

SDC 仅切除异步输入管脚到各同步器第一级 D 引脚的路径，保留级间时序分析；覆盖 SoC 和 UI 两处同步器。

Efinity 使用 `get_pins`，不支持此次最初尝试的 `get_registers`。UART RX 使用生成 IP 内部的输入同步器。

## 5. 文件改动索引

| 文件 | 作用 |
|---|---|
| `rtl/soc_integration/qse_gpio_sync.sv` | 新增四路同步与极性归一化 |
| `rtl/soc_integration/qse_ui_control.sv` | 新增 RTL 消抖、按键切换、格雷码解码和帧边界更新 |
| `rtl/soc_integration/soc_video_ddr_integration.sv` | 接入 GPIO0 与 UART1 |
| `rtl/ti60f225_oob_top.v` | 新端口、UI 控制、OSD 与显示模式连接 |
| `rtl/soc_integration/osd_text_double_buffer.sv` | 复用现有字体路径显示档位标签 |
| `rtl/style/style_video_system.sv` | 传递显示模式 |
| `rtl/style/style_display.sv` | 对比／单幅 DMA 与居中窗口 |
| `ti60f225_oob.peri.xml` | 六个新增管脚与电气配置 |
| `ti60f225_cam_hdmi.xml` | 将同步模块加入实际构建源文件列表 |
| `ti60f225_oob.sdc` | 新增异步输入约束 |
| `soc/efx_sapphire_soc/soc/` 下的配置、包装、模板及相关生成网表 | UART1 SoC 重新生成及接口同步 |
| `software/bsp/EfxSapphireSoc/include/soc.h` | 同步 UART1 定义 |
| `tools/generate_qse_soc.py` | 可重复执行的 Sapphire 生成流程 |
| `tools/configure_qse_io.py` | Interface Designer 管脚配置 |
| `tools/test_qse.py`、`tests/qse*_tb.sv` | 管脚、GPIO、UART、UI、OSD 和显示回归 |
| `tools/package_qse_ui.py` | 候选产物、源码快照和哈希清单打包 |
| `QSE_UI.md` | 使用及重建说明 |

## 6. 验证结果

### 6.1 仿真与软件编译

- GPIO：全部 16 种组合、两级同步延迟、极性与复位通过。
- UART：实际 Efinity 生成的控制器完成 BMB 配置与 8N1 TX/RX 回环。
- UI：默认值、抖动拒绝、长按、再次按下、帧边界发布及格雷码解码通过。
- 标签：四个精确字符串以及关闭后的 RGB 旁路通过；19,200 个像素的标签／同步对齐检查通过。
- 显示：对比 → 单幅 → 对比三帧，1,536,000 个图像像素检查通过，无模拟欠流或 DMA 错误。
- 字体：对照既有不可变基线字体通过。
- 旧 OSD：52,800 个精确像素、双页、位置、颜色及流水线对齐回归通过。
- 现有固件使用新 BSP 重新编译通过；UI 无需增加 C 消抖逻辑。

### 6.2 Efinity 最终构建

最终输出目录：`outflow_qse_ui_final/`。

| 指标 | 最终 QSE UI 候选 |
|---|---|
| 综合／接口／布局布线／位流生成 | 通过 |
| 最差受约束 setup 裕量 | +0.281 ns |
| 最差受约束 hold 裕量 | +0.026 ns |
| XLR | 56,338 / 60,800 |
| RAM Block | 239 / 256 |
| DSP | 140 / 160 |

相对本次已有的 QSE-only 布局结果，XLR 从 56,047 增加到 56,338，净增 291；RAM 与 DSP 不增加。此比较不是对最初未接 QSE 的主线比较。

`outflow_qse_ui/` 是已放弃的中间尝试，不是最终交付。优先使用带源码快照和清单的版本化交付目录。

## 7. 重建命令

在工程目录执行：

```bash
# 软件／RTL 定向回归，使用普通 Python 环境
python tools/test_qse.py

# Efinity 环境只在其构建 shell 内加载
source /home/goodmann/efinity/2026.1/bin/setup.sh

efx_run ti60f225_cam_hdmi.xml --prj -f compile \
  --output_dir outflow_qse_ui_final

efx_run ti60f225_cam_hdmi.xml --prj -f pgm \
  --output_dir outflow_qse_ui_final
```

`pgm` 是生成位流，不是烧录；本次没有调用 `program`。

注意：Efinity setup 会设置 `PYTHONHOME/PYTHONPATH`。回到普通 Python 测试前应换一个干净 shell，或先执行 `unset PYTHONHOME PYTHONPATH`。Interface Designer 若从旧 GUI 状态保存工程，可能覆盖新增源文件列表，构建前须确认 `qse_gpio_sync.sv` 仍在工程中。

## 8. 上板检查与遗留限制

- [ ] 核对子卡连接器方向、脚号和 3.3V 逻辑电平。
- [ ] 逐个旋钮档位确认实际标签与物理顺序。
- [ ] KEY0 按下关闭，再次按下开启；长按不连发，统计文字刷新不自动重新开启。
- [ ] KEY1 在对比与居中单幅间切换，默认对比。
- [ ] 连续操作旋钮和按键，确认无半帧切换、闪烁及显示欠流。
- [ ] 确认权重及实际风格不随标签切换，UART0 调试输出保持正常。

继承的部分 JTAG 时钟／约束警告和未用接口端口提示仍存在；受约束路径裕量为正不等于所有外部接口均已完整约束。日志中另有继承的 `cannot find correct IV value` 警告。Icarus 对既有字体 always_comb 敏感列表及测试台 force 给出支持限制提示，但像素参考检查通过。

仿真和离线构建不能替代板上电气、消抖手感及长时间显示稳定性验证。

## 9. Efinity 运行库环境修复（独立于 FPGA 功能）

此次会话另修复了 Efinity 启动时的 libstdc++ 兼容性警告：

- Efinity `lib/libstdc++.so.6` 改为链接系统 `libstdc++.so.6.0.33`，保留原自带 `6.0.32` 实体文件。
- `bin/setup.sh` 改为读取实际库版本，不再固定按 32 比较；未关闭兼容性检查。
- 环境加载、命令行入口及主要工具动态依赖检查通过。
- 备份及验证记录：`/home/goodmann/efinity/2026.1/backups/libstdcxx-system-runtime/`。

这是本机安装环境调整，不属于 RTL 源码或位流功能。工程开始前已有的文档删除及其他本地改动不属于本功能，不应作为本次实现内容一并提交。
