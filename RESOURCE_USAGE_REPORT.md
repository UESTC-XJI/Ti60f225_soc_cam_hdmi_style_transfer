# Ti60F225当前资源占用报告

本报告对应Gamma移除、统一`defines.v`配置版，分支`feature/highlight-detail`，工作区`C:/OneDrive/comp/Ti60F225_DemoBoard_v4/soc_hdmi_test/Ti60f225_soc_cam_hdmi_highlight`。Efinity 2026.1.132、Ti60F225 I3，使用`ti60f225_cam_hdmi.xml`完整compile通过，bitstream生成于2026-10-06 20:42:27。包含摄像头、DDR、HDMI、AE、提亮、直方图及USER1/USER2 Debugger；尚未集成Sapphire CPU，预留APB模块未实例化。

**当前物理逻辑占用28,278 / 60,800（46.51%），剩余32,522个XLR。相比原Gamma版53,330（87.71%），减少25,052个XLR，降低41.20个百分点。**

## 1. 整工程物理资源

| 资源 | 已使用 | 总容量 | 占用率 | 剩余 |
| --- | ---: | ---: | ---: | ---: |
| XLR（含布线） | 28,278 | 60,800 | 46.51% | 32,522 |
| 内部存储块 | 123 | 256 | 48.05% | 133 |
| DSP | 11 | 160 | 6.88% | 149 |
| GBUF | 19 | 32 | 59.38% | 13 |
| RBUF | 1 | 32 | 3.12% | 31 |

工具的Inputs 120/1,703、Outputs 348/2,267为接口资源口径，不是F225封装引脚数量。

## 2. XLR组成

以下互斥分类可相加；LUT与FF共享时不重复计算。

| XLR用途 | 数量 | 占芯片容量 |
| --- | ---: | ---: |
| 仅LUT4 | 12,245 | 20.14% |
| LUT4+FF | 6,205 | 10.21% |
| 仅加法器 | 1,779 | 2.93% |
| 加法器+FF | 693 | 1.14% |
| SRL8 | 1,320 | 2.17% |
| 仅FF | 6,036 | 9.93% |
| 逻辑合计 | 28,278 | 46.51% |
| 额外布线 | 0 | 0.00% |
| 总计 | 28,278 | 46.51% |

COMB4、COMB4+FF及SRL8+FF均为0。SRL8专用容量14,720、使用1,320（8.97%）是另一种分母，不能加到XLR百分比中。

## 3. 最终映射原语

| 原语 | 数量 | 原Gamma版 | 变化 |
| --- | ---: | ---: | ---: |
| EFX_LUT4 | 18,448 | 35,357 | -16,909 |
| EFX_FF | 12,934 | 20,724 | -7,790 |
| EFX_ADD | 2,472 | 2,500 | -28 |
| EFX_SRL8 | 1,320 | 1,320 | 0 |
| EFX_DSP48 | 9 | 9 | 0 |
| EFX_DSP24 | 2 | 2 | 0 |
| EFX_RAM10 | 119 | 120 | -1 |
| EFX_DPRAM10 | 4 | 4 | 0 |
| EFX_GBUFCE | 1 | 1 | 0 |

LUT和FF数不能直接相加作为物理XLR数量。最终原语统计取综合日志最后一个Resource Summary，包含USER2自动Debugger；`ti60f225_oob_top.res.csv`是USER2插入前统计，存储块为92而非最终123。

## 4. 一级模块资源分布

来自`hier_util.rpt`，包含各模块子层次；XLR小数为工具归属估算，父子不可重复相加。

| 实例 | 功能 | XLR估算 | 占芯片容量 | 存储块 | DSP |
| --- | --- | ---: | ---: | ---: | ---: |
| `u_ddr3_top` | DDR3控制器/PHY/FIFO | 6,181 | 10.17% | 39 | 0 |
| `information_overlay` | 信息叠加，含直方图 | 4,161 | 6.84% | 0 | 0 |
| `inst_efx_csi2_rx` | MIPI CSI接收 | 3,405 | 5.60% | 11 | 0 |
| `edb_top_autodbg_inst__` | USER2自动逻辑分析仪 | 3,131 | 5.15% | 31 | 0 |
| `checker0` | 图像缓存/DDR访问 | 2,730 | 4.49% | 27 | 0 |
| `debug_edb_top_inst` | USER1 Debugger/VIO | 2,386 | 3.92% | 3 | 0 |
| `ae_controller` | AE控制 | 1,556.5 | 2.56% | 0 | 0 |
| `dvi_encoder_m0` | HDMI/DVI编码 | 1,441 | 2.37% | 2 | 0 |
| `ae_meter` | 曝光前测光 | 514 | 0.85% | 0 | 1 |
| `debayer_top` | Debayer/RGB增益 | 493 | 0.81% | 4 | 2 |
| `u2_i2c_master_ctrl_top` | 摄像头I2C | 443 | 0.73% | 2 | 0 |
| `cvo_axi_inst` | 视频DDR输出接口 | 356 | 0.59% | 2 | 0 |
| `display_meter` | 提亮后测光 | 334 | 0.55% | 0 | 0 |
| `automatic_lift` | 自动提亮控制 | 206 | 0.34% | 0 | 0 |
| `ae_status_mailbox` | CDC消息传递 | 154.5 | 0.25% | 0 | 0 |
| `lift_adjustment` | 暗部/中间调提亮 | 148 | 0.24% | 2 | 4 |
| `tone_adjustment` | 调色 | 133 | 0.22% | 0 | 4 |
| `tone_control_mailbox` | CDC消息传递 | 94.5 | 0.16% | 0 | 0 |
| `ae_statistics_mailbox` | CDC消息传递 | 70 | 0.12% | 0 | 0 |
| `osd_status_mailbox` | CDC消息传递 | 42 | 0.07% | 0 | 0 |
| `display_status_mailbox` | CDC消息传递 | 37.5 | 0.06% | 0 | 0 |
| `osd_control_mailbox` | CDC消息传递 | 14 | 0.02% | 0 | 0 |
| `inst_reset_ctrl` | 复位控制 | 1 | 0.00% | 0 | 0 |
| 顶层直接逻辑 | 一级实例以外逻辑 | 246 | 0.40% | 0 | 0 |
| 总计 | 含全部子层次 | 28,278 | 46.51% | 123 | 11 |

独立核对：所有一级实例合计28,032，加顶层自身246为28,278；存储块合计123，DSP合计11。

## 5. 主要变化及后续余量

Gamma原实例占24,810个XLR和1块存储，1024×10位表因异步读取而映射到逻辑。当前已删除整个实例、曲线文件和运行时控制，层次报告不再存在Gamma实例。整工程净减少25,052个物理XLR，包含综合重新优化、Debugger探针删除及布线资源变化，不能把净差全部归为Gamma模块自身。

宏配置重构覆盖103个可编辑RTL文件；展开后的代码token与迁移前一致，唯一功能差异是Gamma删除。宏不产生额外硬件。配置说明和迁移审计见`RTL_CONFIG_README.md`。

信息叠加父模块4,161 XLR，其中直方图3,595、其余合成/坐标/同步566；两组OSD CDC另占56，总计4,217。直方图仍用寄存器数组，0块RAM/0 DSP。以后增加CPU用原始直方图，可优先评估同步块RAM和顺序清零。

Debugger合计5,517 XLR、34块存储（USER1为2,386/3，USER2为3,131/31）。DDR为6,181 XLR、39块存储。剩余逻辑32,522、存储133块、DSP149块，明显增加后续SoC和视频处理的空间，但必须以集成后编译结果确认。SoC demo包含DDR等已有模块，不能将其总资源简单相加；应共享DDR并加入仲裁和地址分区。

## 6. 时序及验证范围

完整map、debugger、interface、pnr及bitstream生成均PASS。最终时序报告列出的建立/保持关系均为正裕量：

| 时钟域 | 目标频率 | 建立裕量 |
| --- | ---: | ---: |
| HDMI像素 | 148.5MHz | 0.906ns |
| 视频 | 74.25MHz | 7.738ns |
| AE | 5MHz | 184.164ns |

基础工程仍有JTAG及DDR接口约束/引脚缺项、时序环路切断等警告；上述结论仅覆盖当前报告实际分析的受约束路径，不等于所有板级路径已验证。未进行硬件下载。

回归仿真全部通过：直方图Y/R/G/B、两帧1080p叠加、APB寄存器、均值/高光统计、提亮全129档单调性、AE固定/比例/预测模式及稳定性、异步CDC、I2C初始化/运行时曝光、两帧1080p Debayer到测光链路。另对103个RTL进行宏展开token核对，并核对厂商加密内容不变。

## 7. 原始证据

- 物理总资源：`outflow/ti60f225_oob.place.rpt`。
- 层次资源：`outflow/ti60f225_oob.hier_util.rpt`。
- 最终映射原语：`outflow/ti60f225_cam_hdmi.log`最后一个Resource Summary。
- 最终时序：`outflow/ti60f225_oob.timing.rpt`。
- 新bitstream：`outflow/ti60f225_oob.bit`，2,557,320字节。
- SHA-256：`ddb334960bb6b93a7c08faec2bdc877d418454de06fc474f7f5beba23eb957ac`。
- 原Gamma版对比基线：RTL `19a43ff`，bitstream时间2026-10-06 19:45:49，详细旧报告可在提交`748553b`中查看。
