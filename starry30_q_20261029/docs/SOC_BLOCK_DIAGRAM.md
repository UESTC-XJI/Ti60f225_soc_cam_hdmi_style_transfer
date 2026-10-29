# 当前 SoC 框图

核对日期：2026-10-09。对应当前统一APB与SoC清理源码；新硬件产物记录见`reports/soc_cleanup/README.md`。旧硬件AE、旧I²C主机与无效OSD/状态mailbox已从当前顶层移除，CPU独占摄像头I²C。虚线表示控制或统计反馈，实线表示主要数据/总线连接。

```mermaid
flowchart TB
    PC["PC：IDE / 串口终端"]
    CAM["SC431HAI 摄像头<br/>1920×1080，CSI RAW10"]
    DDR["板外 DDR3<br/>CPU 程序/数据 + 视频三帧缓存"]
    HDMI["HDMI 显示器<br/>1280×720 / 60 Hz"]

    subgraph FPGA["Ti60F225 FPGA"]
        subgraph SOC["Sapphire 控制子系统 · 100 MHz"]
            CPU["VexRiscv · RV32IM<br/>软件 AE / AWB / 初始化 / 诊断"]
            LOCAL["I/D Cache 各 4 KiB<br/>片上 RAM 4 KiB"]
            PERIPH["UART / SPI / GPIO<br/>CLINT / PLIC"]
            I2C["Sapphire I²C 主机"]
            APB["统一视频 APB<br/>0xF8100000<br/>参数 / 统计 / OSD / 故障"]
        end

        subgraph CAP["采集与 ISP · CSI 50 MHz → 148.5 MHz"]
            CSI["MIPI CSI-2 接收"]
            GEAR["RAW Gearbox / CDC<br/>RAW10 截为 RAW8 · 双像素"]
            GAIN["Bayer R/G/B 数字增益"]
            DEB["行缓存 + Debayer<br/>双像素 RGB888"]
            RESIZE["面积缩放 3:2<br/>1080p → 720p"]
            STATS["统一采集统计<br/>RAW AWB + RGB AE/高光<br/>64 bin Y 直方图"]
        end

        subgraph MEM["共享 DDR 数据通路 · 100 MHz"]
            FB["视频 Frame Buffer<br/>写入 / 读出 DMA"]
            AXI["CPU / 视频 AXI 仲裁桥<br/>128 bit，响应归属与 ID 保留"]
            CTRL["唯一 DDR3 控制器 / PHY"]
        end

        subgraph DISP["显示流水线 · 74.25 MHz"]
            CVO["CVO<br/>720p60 时序"]
            TONE["色调修正 + 手动亮度映射"]
            OSD["直方图叠加 / 双缓冲文字 OSD"]
            SEL["帧边界输出选择"]
            BAR["独立启动彩条"]
            ENC["DVI/TMDS 编码与串行输出"]
        end
    end

    PC <-->|"JTAG USER1 调试/下载"| CPU
    PC <-->|"UART"| PERIPH
    CPU <--> LOCAL
    CPU <--> PERIPH
    CPU <--> I2C
    CPU <-->|"APB"| APB
    I2C -.->|"初始化 / AE 曝光"| CAM

    CAM --> CSI --> GEAR --> GAIN --> DEB --> RESIZE --> FB
    GEAR -.->|"增益前 RAW"| STATS
    DEB -.->|"增益后 RGB"| STATS
    STATS -.->|"同帧统计 / CDC"| APB
    APB -.->|"AWB gain · 帧边界提交"| GAIN
    APB -.->|"显示参数"| TONE
    APB -.->|"文字 / COMMIT"| OSD
    APB -.->|"VIDEO_READY"| SEL

    CPU <-->|"AXI4 · 程序/数据"| AXI
    FB <-->|"AXI4 · 帧读写"| AXI
    AXI <--> CTRL <--> DDR
    FB -->|"AXI-Stream"| CVO --> TONE --> OSD --> SEL --> ENC --> HDMI
    BAR --> SEL
```

CPU主固件链接在DDR地址`0x00001000`，不是片上RAM；独立片上RAM位于`0xF9000000`，容量4 KiB。CPU DDR scratch预留窗口起始`0x01000000`，视频三帧缓存基址`0x04000000`。DDR参数与地址范围以当前RTL/链接脚本为准。

## AE / AWB 闭环

```mermaid
flowchart LR
    SENSOR["摄像头曝光"] --> RAW["增益前 RAW"]
    RAW --> GAIN["RAW R/G/B gain"] --> RGB["Debayer RGB"]
    RAW --> AWBS["AWB：R/Gr+Gb/B 累加"]
    RGB --> AES["AE：平均亮度 / 高光"]
    AWBS --> ST["统一统计 + 同帧版本 + CDC"]
    AES --> ST
    ST --> APB["统一 APB"] --> CPU["CPU 软件 AE/AWB"]
    CPU -.->|"I²C · Group Hold / 延迟读回确认"| SENSOR
    CPU -.->|"APB · 帧边界 APPLY/ACK"| GAIN
```

AWB为增益前RAW灰度世界，默认AUTO；中性色筛选硬件存在但默认关闭，单色场景自动保护尚未实现。AE使用增益后、缩放前RGB测光。显示端另有亮度统计与绘图直方图；自动lift关闭，手动lift启用。软件直方图快照默认不开启，显示直方图默认关闭。

## OSD连接与提交

```mermaid
flowchart LR
    V["色调 / 手动亮度映射后的视频"] --> H["hdmi_info_overlay<br/>直方图叠加"]
    H --> T["osd_text_double_buffer<br/>动态文字叠加"]
    T --> S["摄像头 / 启动彩条选择"] --> HDMI["HDMI"]
    CPU["CPU / 统一 APB"] -.->|"display_config：帧边界跨域提交"| H
    CPU -.->|"非活动字符页 / COMMIT / 位置 / 颜色"| T
    T -.->|"ACK / 活动页 / BUSY"| CPU
```

直方图参数直接使用HDMI域的video_display_hist，无额外osd_control_mailbox。直方图模块的文字输入关闭，文字由两页×80字符的动态文字模块绘制。COMMIT在帧边界切换字符页、位置、颜色并返回ACK。文字使能单独经过两级同步并锁存在下一帧边界，无需COMMIT，不在帧中改变。未接入最终输出的fixed_text_osd已移除。

## 时钟与复位

| 时钟域 | 频率 / 用途 |
| --- | --- |
| core_clk | 100 MHz，CPU / APB / AXI |
| i_mipi_rx_pclk | 50 MHz，CSI接收输出 |
| vid_clk_dvi2 | 148.5 MHz，RAW增益 / Debayer / 采集统计 / 缩放 |
| hdmi_tx_slow_clk | 74.25 MHz，CVO / 色调 / OSD / TMDS编码 |
| HDMI串行时钟 | 371.25 MHz，TMDS输出 |

PLL锁定与DDR校准通过`ddr_startup_barrier`同步放开CPU和视频访问。启动彩条与HDMI输出复位不等待CPU或DDR。采集gearbox/resize fault为锁存故障，单独CPU重启不能清除。

## 核对源码

- [顶层连接](../rtl/ti60f225_oob_top.v)
- [Sapphire与共享DDR集成](../rtl/soc_integration/soc_video_ddr_integration.sv)
- [AXI共享桥](../rtl/soc_integration/axi_shared_ddr_2m.sv)
- [统一视频APB](../rtl/soc_integration/video_apb_ctrl.sv)
- [统一采集统计](../rtl/isp/capture_frame_stats.sv)
- [RAW增益与Debayer](../rtl/debayer/debayer_top_2to1.v)
- [CPU地址与Cache配置](../software/bsp/EfxSapphireSoc/include/soc.h)
- [固件链接地址](../software/firmware/app.ld)
