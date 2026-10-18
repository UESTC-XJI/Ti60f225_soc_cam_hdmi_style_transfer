# Ti60F225 项目交接：统一 APB / 软件 AE / AWB 已实施

## 2026-10-12 P1/P2/P3资源优化（当前源码最新状态）

用户要求修订资源优化方案并实施P1/P2/P3，无开发板连接。本轮已将采集/显示直方图、APB缓存、RAW前行和文字页改同步BRAM；保留冻结META、标量发布及ACTIVE镜像。关闭自动视频Debugger，保留CPU USER1/JTAG DEBUG；CSI仅保留RAW10实例，不改厂商源码。文字OSD RGB/DE/HS/VS输出延迟为三拍。

本轮同工具同约束完整构建XLR为55,159（90.72%）→34,767（57.18%），RAM147→153，DSP19不变。优化版map/interface/PNR/PGM PASS，最终setup最小0.407ns、hold0.026ns；完整1080p统计、定向RAM/APB/逐像素OSD、原RTL/启动/诊断/resize/DMA/CVO/shared-DDR及真实RV32固件回归PASS。保留既有JTAG/接口约束警告，厂商加密CSI未进行完整协议仿真。

当前新bit和未修改配套ELF在[resource_optimization](../reports/resource_optimization/README.md)，输入/报告哈希及RAM原语见同目录manifest.json/validation.json；修订方案见[RESOURCE_OPTIMIZATION_PLAN](RESOURCE_OPTIMIZATION_PLAN.md)。本轮未上板/未烧录，实际MIPI、显示及AE/AWB仍待验证；下节10月9日实板结论属于旧bit，不能视作本轮硬件验证。P4/P5/P6和加速器未实施。

## 2026-10-09 实板排障最新状态（优先于后文）

- 用户已授权清理SoC遗留模块，并明确osd_control_mailbox可整体移除与文字en2同步遗漏。当前顶层已去掉旧硬件AE/I²C及其CDC、owner mux、固定文字、无消费者状态CDC、冗余直方图控制CDC、自动lift反馈控制及旧声明；保留历史源码/测试，活动XML仅移除10项旧源。I²C直接开漏连接，手动lift保留0～128限幅，直方图直连HDMI域已提交配置。文字en2补齐两级同步，active_enable在VS锁存，无COMMIT开关，原两页80字符COMMIT/ACK保留。
- `tools/test_soc_cleanup.py`通过实际顶层I²C/全部256档手动强度与旧模块等价、OSD异步COMMIT/ACK/活动页保护/帧中开关/关闭时提交/RGB透传及缺失en2反例。统一APB、完整RTL含两帧1080p、启动彩条、帧率诊断、resize/DMA/CVO及200次并发CPU共享DDR回归全部PASS。新bit为`reports/soc_cleanup/soc_cleanup.bit`，Efinity map/debug/interface/PNR/PGM全PASS，setup最小0.260ns/hold0.026ns，采集域setup1.307ns。LUT4 -408/FF -8，RAM/DSP不变。配套ELF为同目录/当前build的AE调整版，无软件算法新变化。硬件效果待用户配置，agent没有烧录。Efinity曾持续写回旧XML，用户已关闭Efinity工程；最终恢复原XML排版，语义与构建输入一致。后续先打开清理后的工程XML刷新列表，再新bit→ELF/F8；新bit配置前停止IDE调试。
- 最新进展：用户重新配置原bit后确认AE开始工作；只读COM4确认RAW/RESIZE30、DISP60、DROP/ERR0，AE/AWB计数均增长且code/err0。用户指出固定光线下小块高亮光源引发抽动。旧算法high>10‰无条件减曝光与低mean增曝光冲突；当前改为高光缓慢降低目标（96～72）、大误差快速比例调整、中小误差阻尼、±4进入保持/±8退出及细调连续3份统计确认。安全帧等待、I²C确认、AWB版本协调保留。新产物`reports/software_3a_ae_tuning/`，推荐build ELF；上一版i2c_fix产物保留。
- 新版真实RV32 ELF回归PASS：延迟生效30FPS明暗阶跃13/27帧收敛、固定场景噪声无写入、小光源0.8～1.4%阈值波动/持续5%高光无持续抽动、耦合AWB增益变化后AE稳定、曝光上下限不反复写入，以及既有故障/启动检查。**新版尚未加载到实板，不能声称已消除实际抽动**。更新时沿用原bit，鉴于已出现热重载采集fault，先停止IDE、重配原bit、加载新ELF一次。后续只读UART验证goal/hold/AE更新及小光源固定场景。
- 用户已成功配置 software_3a.bit 并运行完整固件。IDE localhost error138 已修为127.0.0.1；旧 OpenOCD 残留通过重启后不再占用。native GP 名为x3；运行时读目标内存会使 vendor OpenOCD断言。曾因诊断命令导致调试退出，已明确告知用户；后续避免在IDE GDB活动时外部改变运行状态，优先只读COM4串口。
- 持续彩条根因为固件误判 Sapphire RX_ACK.VALID 的清除语义：实际读后清除，LISTEN/STOP均不清。最终master NACK留下VALID，下一事务TX_ACK受背压阻塞。现发送前drain并在最终读关闭ACK监听；初始化/重试增加有界DROP/RECOVER。RECOVER自带STOP，不能idle补发STOP。实际导入I²C RTL按位从机仿真已复现旧错误并验证修复，RV32模型已修正，原始ELF在新模型中失败。
- 用户加载ACK/RECOVER修复后确认初始化成功；COM4实测RAW30/RESIZE30/DISP60/DROP0/ERR0。但3A首次曝光确认state5。根据用户提供的SC431HAI V1.1手册第23/29页，最新固件读取3802[1:0]，等待CSI与完整采集帧均前进3+delay后再确认曝光，pending不冒充已确认值；增加code/req/rb和AE/AWB计数。延迟读回0～3帧、确认读失败/数值不符/超时与完整main/旧故障回归均PASS。
- 历史故障已通过重配置恢复：反复reload ELF后曾RAW12～13/RESIZE0/DROP1/state7，gearbox/resize fault锁存。只reset CPU无法清除，重新配置原有software_3a.bit后用户确认AE工作；当前采集30FPS。
- 历史ACK修复ELF/BIN/MAP保存于reports/software_3a_i2c_fix；当前推荐为reports/soc_cleanup的新bit及配套ELF。旧release保留。详细实板证据在reports/hardware_debug/camera_*_20261009.log。用户自行完成下载/配置；没有代用户烧录或下载ELF。
- 用户看到DDR pass循环两次属于正常pass0/pass1；app_ddr_errors已实测0。

更新：2026-10-08。本轮用户明确要求完成统一 APB、采集统计、软件 AE/AWB；相应代码、仿真、固件和 FPGA 编译已完成，尚未烧录。下文历史快照描述的是实施前状态，不能覆盖本节。

- 工程根、分支、HEAD仍同历史记录；改动未提交，保留了用户已有方案修改和删除的“新建 文本文档.txt”，未创建子agent。Efinity XML自动重排已核对语义后恢复。
- 当前入口 `rtl/soc_integration/video_apb_ctrl.sv`：一个16位APB窗口，兼容0x000～0x030，扩展到0x1a0（未定义地址拒绝），VERSION=0x10000/CAPS=0x1ff。采集/显示参数独立帧边界提交，ACK镜像/序号可查询。
- `capture_frame_stats.sv` 合并AE亮度/高光、64bin Y及gain前RAW AWB；实际gearbox输出RAW8，不是RAW10。1080p为32400 AE样本与16200 AWB单元；同帧标量整包CDC，hist冻结META逐项传输，CPU读取不会锁住实时统计。
- 固件默认软件AE/AWB。读取真实VTS，真实NACK/timeout/START/STOP dropped检查，Group Hold与读回确认，CSI帧开始附近写曝光并保守等待至少三个源/采集帧。AWB两份绿色、目标限幅/平滑/步幅、固定/自动/锁定、CAPTURE提交及AE协调均已实现。主循环1ms轮询，运行OSD非阻塞，DDR压力测试只在启动执行。
- 观测 `app_3a` 和每秒UART `3A state ...`；`app_awb_mode`=0固定/1自动/2锁定。`app_hist_enable`=1启用非阻塞读快照，默认0。
- Efinity map/debug/interface/PNR/PGM全PASS；最终最小setup=0.397ns/hold=0.026ns，采集域setup=1.537ns。固件BIN为10512字节。统一APB/真实Debayer小尺寸及完整1080p、RAW/RGB短VS帧尾重叠、实际RV32控制及完整main/故障注入、旧启动/诊断/RTL/resize/shared DDR回归均PASS。
- 新配套产物在 `reports/software_3a/`：software_3a.bit、soc_video_app.elf/bin/map、timing/resources报告、测试日志/manifest。bit SHA256=F2BBDC0A73C9979784AF07BEB0113B783705777A44B40F1E4DA34A7C30FA0F9F；ELF=9231F57B87E4B81984AB4272E87CF7F23AFF352CC02F8B0171AEE6A4C40AC7F6。旧保存产物保留。
- 先读 [实现说明](VIDEO_3A_IMPLEMENTATION.md)、[产物验证记录](../reports/software_3a/README.md)及更新后的烧录README。真实VTS和颜色效果尚未实板确认；模型不是物理全系统仿真。RAW/RESIZE约12FPS原因仍未知，未改VTS/PLL/模拟gain，未标定黑电平，自动lift继续关闭。
- 用户此前暂不烧录的要求仍保留；本轮未访问板卡、USB/JTAG或串口。后续实板需要配套bit/ELF，并检查灰/白卡、光源变化、单色场景及曝光读回。

## 历史交接快照（本轮实施前，保留排障与工具背景）

更新时间：2026-10-08。本文汇总代码现状、用户目标、已验证结果及下一步方案，供另一个 agent 在没有完整聊天记录时接手。方案已完成不等于硬件或软件功能已实施。

## 1. 先读这些信息

- 工程根目录：`C:/OneDrive/comp/Ti60F225_DemoBoard_v4/soc_hdmi_test/Ti60f225_soc_cam_hdmi_soc_sim`。
- 环境：Windows、PowerShell、Efinity 2026.1、Efinity RISC-V IDE 2026.1。与用户用中文沟通。
- 当前分支：`feature/soc-hardjtag-sim`。
- 当前 HEAD：`5d9d86e338cc84b92c432a5dc7f8b656ac73d654`；提交标题为“完成cpu集成 通过iic初始化摄像头和显示模块 未开启自动曝光 烧录和下载步骤见README_PROGRAMMING.md”。
- 原始集成基线：`3ab82f8319c8f12284078f6373327093e50bb40e`；不要直接切回基线覆盖现状。
- 本交接文件创建前，`git status --short` 仅显示 `docs/VIDEO_APB_CONTROL_PLAN.md` 修改；既有代码已经进入当前提交。统一方案修订尚未提交，交接文件也是新增文件。接手先重新检查 Git 状态，保留用户后续修改，不擅自提交或重置。
- 未发现适用的 `AGENTS.md`。用户未要求使用子 agent；当前工作不主动创建子 agent。

建议先读 [统一 APB / AE / AWB / 直方图方案](C:/OneDrive/comp/Ti60F225_DemoBoard_v4/soc_hdmi_test/Ti60f225_soc_cam_hdmi_soc_sim/docs/VIDEO_APB_CONTROL_PLAN.md)，再读 [集成日志](C:/OneDrive/comp/Ti60F225_DemoBoard_v4/soc_hdmi_test/Ti60f225_soc_cam_hdmi_soc_sim/INTEGRATION_LOG.md) 和 [烧录运行说明](C:/OneDrive/comp/Ti60F225_DemoBoard_v4/soc_hdmi_test/Ti60f225_soc_cam_hdmi_soc_sim/README_PROGRAMMING.md)。本文中的当前会话补充优先于旧文档中尚未更新的状态描述。

## 2. 项目目标

原始目标是将 Sapphire / VexRiscv CPU 集成到现有 SC431HAI 摄像头 → 720p HDMI 工程，在一个共享 DDR 控制器上并发运行视频与 CPU，由 CPU 初始化摄像头、控制 OSD、测试 DDR，并支持 JTAG 下载和调试。12 项集成目标的逐项实现与证据已记录在集成日志。

当前后续方向已经确定为：

1. HDMI 在 CPU 初始化摄像头之前持续输出合法 720p 彩条，初始化成功后切入摄像头视频。此项已实现、编译与仿真通过。
2. 分别观测摄像头原始 VS、缩放完成和显示帧率。此项已实现；用户报告 RAW 与 RESIZE 均约 12 FPS。
3. 将自动曝光 AE 移到 CPU，保留 FPGA 像素统计；通过现有 Sapphire I²C 调整曝光。此项仅完成调查和方案，未实现。
4. 采用 CPU 自动白平衡 AWB，复用现有 RAW RGB gain。此项仅完成算法和方案，未实现。
5. 尽量减少 APB 接口数量：保持一个视频 APB 外设，将 OSD、ISP 参数、AE/AWB 数据、直方图快照和诊断统一编址。此项仅完成详细方案，未实现。
6. 将采集侧 AE 亮度/高光、Y 直方图和 AWB 颜色统计合并为一个 `capture_frame_stats` 模块；保持同帧数据一致并避免重复采样。用户已同意将此结构写入方案，文档已更新。

## 3. 实际代码与运行状态

### 3.1 视频与 SoC 基础集成

现有链路：SC431HAI RAW10 1920×1080 / 4 lane CSI → RAW gearbox → RAW RGB gain / Debayer → 采集侧 AE meter → area resize 1080p→720p → DDR frame buffer → CVO → tone / lift → HDMI 绘图直方图及 overlay → OSD → HDMI startup selector → DVI / TMDS。

采集双像素处理域 `vid_clk_dvi2` 为 148.5 MHz，HDMI 单像素域 74.25 MHz，TMDS 为 371.25 MHz，CPU / APB core 为 100 MHz；CSI 接收像素域为 50 MHz。共享 DDR bridge 保存完整 CPU AXI ID 与响应归属，CPU 和视频不各自占用第二个 DDR 控制器。复位屏障等待 PLL 锁定和 DDR 校准，再放开需要 DDR 的 CPU / 视频访问。

已具备完整固件 `_start`、GP/SP/BSS 初始化、异常记录、UART/I²C/CLINT、摄像头 ID 与初始化表、DDR scratch 测试、OSD 字符双缓冲与每秒统计。CPU 独占物理摄像头 I²C，旧 RTL master 不再驱动物理 SDA/SCL。

### 3.2 HDMI 启动彩条：已实现

- 1280×720 / 60 Hz，74.25 MHz；总时序 1650×750，HFP/HSP/HBP=110/40/220，VFP/VSP/VBP=5/5/20，HS/VS 正极性，八色条各160像素。
- 彩条发生器和输出编码复位只依赖 PLL 锁定及 HDMI 域复位同步，不等 DDR 或 CPU 初始化。
- APB `VIDEO_READY=0xf8100028`，bit0 RW，复位0；固件 main 首先清0，DDR 测试、摄像头初始化和 OSD COMMIT/ACK 成功才置1。
- CDC selector 观察视频 VS，完成彩条帧后空白等待合法视频帧边界再切入。返回彩条也在边界切换；两路相位独立，显示器可能短暂重新锁定，未承诺无缝切换。
- 彩条旁路 ISP/OSD；后台摄像头、DDR 和 OSD 继续工作。旧 ELF 不写 VIDEO_READY 会一直显示彩条，必须使用配套固件。

### 3.3 RAW / RESIZE 诊断：已实现

| 指标 | 实际统计语义 |
|---|---|
| RAW | `w_mipi_rx_vs` 下降沿事件 / 秒；仅证明 CSI 帧边界，不证明整帧像素正确 |
| RESIZE | `resize_completed_frames` 完成事件 / 秒；位于 DDR frame buffer 之前 |
| DISP | CVO `ch0_vs` 上升沿 / 秒；不能等同于每秒显示的新摄像头帧数 |
| DROP | 现有 `capture_fault` 上升沿计数；故障可能锁存，不能视为精确丢帧数量 |
| ERR | 当前 APB 暴露的 AXI 错误状态/计数低8位；不是全部 CSI、DDR、显示错误的总和 |

三路帧事件在源域提取，以 toggle CDC 进入 core 域，在同一1秒窗口锁存。`0xf810002c` 为 RAW_FPS，`0xf8100030` 为 RESIZE_FPS，低16位只读。`0xf8100024` 保持高16位 DISP、低16位 RESIZE。OSD/UART 显示 `RAW n RESIZE n DISP n DROP n ERR n`。统计跨窗可能差1帧，需要看连续样本。

用户在诊断讨论后报告 **RAW 和 RESIZE 都约12**。这支持优先调查传感器模式、时钟与帧长；不支持仅凭现象认定缩放模块丢掉了大部分帧。原始 VTS 尚未真实读回；不要声称已经确定12FPS原因，也不要承诺 AE 自动提高到30FPS。

### 3.4 AE / AWB / histogram：现状与待实施严格区分

| 功能 | 当前实际状态 |
|---|---|
| RAW RGB gain | 已有 Q8.8 增益、右移8位并按RAW位宽饱和；目前固定 R=0x0168、G=0x0100、B=0x01a9 |
| AWB | 未实现；没有自动颜色统计/APB读取/软件调整回路 |
| 采集 AE meter | `ae_frame_stats` 仍在 gain 后RGB、tone/lift/OSD前统计mean、高光数量/千分比；已有硬件除法 |
| 旧硬件 AE | controller 保留，但顶层 `ae_enable=0`；旧 AE 没有物理 I²C 所有权，不能直接打开enable宣称有效 |
| 软件 AE | 未实现；用户曾要求“打开自动曝光”，当前仍未完成此功能 |
| 采集统计到CPU | 未实现；现有 `ae_statistics_mailbox` 接到旧AE的CLK_5M域，不是CPU接口 |
| HDMI 直方图 | `hdmi_frame_histogram` 保留，位于tone/lift之后；64bin输出为按峰值归一化绘图高度，计数在处理时清除；绘图默认关闭，综合可能裁去部分逻辑 |
| 原始64bin给CPU | 未实现；现有 `o_height` 不是原始bin count，也不适合直接作为传感器AE反馈 |
| tone / lift | 已恢复基线校准默认启用，两类tone强度32，手动lift强度32；自动lift仍关闭 |
| 统一APB扩展 | 未实现；实际 `osd_apb_regs` 只实现0x000～0x030，方案中0x034以后的地址不可当成现成硬件访问 |

AE 当前采样为双像素、每8个pair时钟/每8行取样，全1080p约32,400个像素样本。高光检测是任一RGB通道达到阈值，不等同于Y直方图高亮bin之和。Y histogram 可以近似均值，但64bin量化无法替代精确Y和。

## 4. 用户认可的最新设计方案

完整寄存器表、CDC协议、算法、实施阶段和验收条件见统一方案。接手实现以该文件的最新修订为准，下面只列关键决策：

- 对外一个 APB 视频外设，基地址 `0xf8100000`；预留4KiB，当前规划使用偏移0x000～0x1ff。先确认上游译码范围与高位无别名，不增加 APB 从端口。
- `capture_frame_stats` 合并采集统计。AE 的Y和、样本数、任一RGB通道高光数与64bin共享gain后RGB采样；AWB使用gain前RAW的完整BGGR 2×2单元，独立暗部/饱和/中性色筛选。
- AWB累计R、Gr+Gb、B与单元数N；R/B各N个样本，G有2N个。CPU目标公式为 `R_Q8=round(256*G_SUM/(2*R_SUM))`、`G_Q8=256`、`B_Q8=round(256*G_SUM/(2*B_SUM))`。中间运算用64位，检查零分母、样本量和候选比例。
- 若统计点改到gain后RGB，必须改用当前ACTIVE gain乘颜色比例的反馈公式；不能混用前后增益统计，也不能从截断RGB准确还原RAW。本方案默认gain前RAW。
- 用当前校正gain做可选中性色筛选，累加仍是gain前RAW。启动先关闭中性色筛选或采用宽筛选，避免严重偏色时没有样本。确认黑电平残余偏置，必要时CPU按各通道样本数扣除标定值。
- AWB保持固定/自动/锁定模式。样本不足保留最后确认值；目标限幅、死区、步幅与约1/4平滑参数保存在软件，不为每个变量加硬件寄存器。灰度世界不能可靠区分整片单色物体和光源偏色，须用灰卡、白卡、不同光源及单色场景验证。
- 硬件只累计，CPU做均值、高光比例和增益计算，替代采集统计里的除法器。显示侧提亮统计及后处理绘图直方图保留为独立用途。
- CAPTURE参数组包含RGB gain与AE/AWB筛选参数，DISPLAY组包含tone/lift/hist显示参数。SHADOW→pending锁定→CDC→本域帧边界ACTIVE→apply-ACK；mailbox接收ACK不等于已生效ACK。
- RAW帧头生效版本随去马赛克流水线传递，不能误标上一帧RGB尾部。整帧AE/AWB标量同包发布，共用序号、帧号、参数版本；CPU前后读序号校验防撕裂。
- 64bin ACQUIRE等待完整帧、冻结完整AE/AWB标量与hist、复制到core缓存、LOCKED_VALID后读，RELEASE后解锁；实时统计继续。需要hist参与决策时读取冻结META，不混用较新的实时标量。
- AE通过现有I²C调整曝光，AWB通过CAPTURE提交数字gain。协调状态机等待曝光N+2与gain版本生效，避免同一旧快照同时触发两个大幅调整；不得让频繁AWB微调饿死AE。

规划bank：0x000～0x03f兼容接口/版本/CAPS；0x040～0x07f gain/tone/提交；0x080～0x0bf lift；0x0c0～0x0ff帧头/AE和计数；0x100～0x13f hist冻结读；0x140～0x17f诊断；0x180～0x1ff AWB。所有扩展均待实现，CAPS只能声明实际完成且通过验证的功能。

## 5. 重要问题与经验

### 5.1 花屏与偏绿

用户已找到彩色斑纹原因：**显示器坏了**；使用早期正常bitstream也出现斑纹。不要继续把斑纹全部归因于SoC集成。用户猜测启动花屏损坏显示器，没有证据证明因果；彩条是改善合法启动输出，不是已证明的损坏修复。

另一个独立软件回退确实存在：移除VIO后gain曾误设三通道255并关闭tone/lift，现已恢复基线校准值。曾实板读回初始化表162个不同寄存器，mismatch=0，但这不包含未写入表的VTS寄存器。

### 5.2 12FPS、曝光与I²C

- SC431HAI初始化表有165次写入，ID=0xCD6B，`301f=0x10`，没有显式写 `320c～320f`。
- 初始曝光 `3e00=01 / 3e01=bb / 3e02=f0`，为7103半行，即3551.5行。手册合法上限 `2×VTS−11` 意味着此曝光需VTS至少3557，但未读回真实VTS，不能据此直接断定帧率原因。
- 软件AE开始前读取 VTS=`{320e[6:0],320f}` 与曝光=`{3e00[3:0],3e01,3e02[7:4]}`。本期只调曝光，不自动改VTS/PLL/传感器gain；帧率调查单独处理。
- Group Hold：`3812=00` → 写曝光字段、保留保留位 → `3812=30`。错误时也尝试释放，逐次检查NACK/timeout，并依据源帧事件等待N+2生效。
- 现有BSP包装 `sapphire_i2c_read16/write16` 无条件返回0！模型中的失败检查不证明真实总线失败可检出。实施软件AE前必须补真实NACK/timeout返回及关键读回验证。
- 当前main有最多250ms阻塞式OSD ACK等待、每秒64KiB DDR scratch和串口输出。不能仅加1ms轮询就宣称AE服务延迟有保障；需非阻塞OSD、合作式调度、DDR分块/诊断模式和日志限频。

### 5.3 JTAG与下载

- FT4232H `0403:6011`，channel1 / Interface1 / MI_01；历史驱动libusb-win32。多次曾在编译或下载期间离线，工具显示 `No USB target detected`；仅返回码0不代表烧录成功。
- CPU使用native VexRiscv USER1；Efinity自动调试器USER2。不要切到标准RISC-V DMI配置。
- OpenOCD正常配置800kHz，readWaitCycles40。默认端口3333/6666/4444，IDE13333/16666/14444，历史临时测试23333/26666/24444。
- 下载前必须CPU `reset halt`，再load、PC=`_start`；曾只改PC后resume不能恢复异常状态，reset halt后恢复成功。保持禁止compressed breakpoints，在`*main`停下后需continue/F8运行。
- vendor target不支持checksum_memory；GDB compare-sections的失败不能直接当作下载损坏，应dump binary memory逐字节比较。
- Windows vendor Jim Tcl不支持file normalize；配套cfg已修复路径分隔符。保留用户IDE launch设置，避免为恢复默认值覆盖用户改动或终止不属于本任务的会话。
- UART曾为COM4，115200/8N1；重新枚举后核对端口。bitstream与ELF必须配套。当前BIN不是Flash启动镜像，DDR程序断电不保留。

## 6. 文档与源代码位置

下表均为实际存在的文件。统一方案里提出的新模块/驱动名称尚未创建，不要当成当前源文件。

| 文件 | 用途与阅读注意 |
|---|---|
| [VIDEO_APB_CONTROL_PLAN.md](C:/OneDrive/comp/Ti60F225_DemoBoard_v4/soc_hdmi_test/Ti60f225_soc_cam_hdmi_soc_sim/docs/VIDEO_APB_CONTROL_PLAN.md) | 最新待实施方案，已含AE/AWB/hist统一结构、寄存器与验证要求；本轮修改未提交 |
| [INTEGRATION_LOG.md](C:/OneDrive/comp/Ti60F225_DemoBoard_v4/soc_hdmi_test/Ti60f225_soc_cam_hdmi_soc_sim/INTEGRATION_LOG.md) | 12项目标、历史修复、编译、仿真与分版本实板证据；尚未记录用户后来报告RAW/RESIZE约12及最新设计讨论 |
| [README_PROGRAMMING.md](C:/OneDrive/comp/Ti60F225_DemoBoard_v4/soc_hdmi_test/Ti60f225_soc_cam_hdmi_soc_sim/README_PROGRAMMING.md) | FPGA与ELF配套选择、IDE/GDB步骤和USB故障排查；阅读不等于授权烧录 |
| [firmware README](C:/OneDrive/comp/Ti60F225_DemoBoard_v4/soc_hdmi_test/Ti60f225_soc_cam_hdmi_soc_sim/software/firmware/README.md) | 完整应用行为、构建和验证边界 |
| [DDR_ADDRESS_MAP.md](C:/OneDrive/comp/Ti60F225_DemoBoard_v4/soc_hdmi_test/Ti60f225_soc_cam_hdmi_soc_sim/docs/DDR_ADDRESS_MAP.md) | 正确地址划分；程序0x1000实际在DDR，不是片上RAM |
| [VIDEO_INTERCONNECT.md](C:/OneDrive/comp/Ti60F225_DemoBoard_v4/soc_hdmi_test/Ti60f225_soc_cam_hdmi_soc_sim/docs/VIDEO_INTERCONNECT.md) | 视频时钟、连接与接口背景；部分为较早链路说明，以当前top为准 |
| [SOC_INTEGRATION.md](C:/OneDrive/comp/Ti60F225_DemoBoard_v4/soc_hdmi_test/Ti60f225_soc_cam_hdmi_soc_sim/docs/SOC_INTEGRATION.md) | 原始SoC接入说明；仍有旧gain=255等描述，不能覆盖当前校准值 |
| [BASELINE_MANIFEST.md](C:/OneDrive/comp/Ti60F225_DemoBoard_v4/soc_hdmi_test/Ti60f225_soc_cam_hdmi_soc_sim/docs/BASELINE_MANIFEST.md) | 基线备份索引；备份位于reports/baseline |
| [SC431HAI手册](C:/OneDrive/comp/Ti60F225_DemoBoard_v4/soc_hdmi_test/摄像头SC431HAI_数据手册_V1.1.pdf) | 42页；PDF第23页曝光半行单位/约束/N+2，第32页VTS；提取文本work/sc431hai_datasheet.txt为辅助资料 |
| [ti60f225_oob_top.v](C:/OneDrive/comp/Ti60F225_DemoBoard_v4/soc_hdmi_test/Ti60f225_soc_cam_hdmi_soc_sim/rtl/ti60f225_oob_top.v) | 视频、SoC、gain、旧AE、彩条和诊断集成入口 |
| [osd_apb_regs.sv](C:/OneDrive/comp/Ti60F225_DemoBoard_v4/soc_hdmi_test/Ti60f225_soc_cam_hdmi_soc_sim/rtl/soc_integration/osd_apb_regs.sv) | 实际APB映射0x000～0x030，扩展时保持旧协议 |
| [soc_video_ddr_integration.sv](C:/OneDrive/comp/Ti60F225_DemoBoard_v4/soc_hdmi_test/Ti60f225_soc_cam_hdmi_soc_sim/rtl/soc_integration/soc_video_ddr_integration.sv) | 实际Sapphire、APB、DDR及外设接入 |
| [hdmi_startup_colorbar.sv](C:/OneDrive/comp/Ti60F225_DemoBoard_v4/soc_hdmi_test/Ti60f225_soc_cam_hdmi_soc_sim/rtl/soc_integration/hdmi_startup_colorbar.sv) | 独立彩条及输出切换 |
| [video_frame_diagnostics.sv](C:/OneDrive/comp/Ti60F225_DemoBoard_v4/soc_hdmi_test/Ti60f225_soc_cam_hdmi_soc_sim/rtl/soc_integration/video_frame_diagnostics.sv) | RAW/RESIZE/DISP事件CDC及共同窗口 |
| [ae_frame_stats.v](C:/OneDrive/comp/Ti60F225_DemoBoard_v4/soc_hdmi_test/Ti60f225_soc_cam_hdmi_soc_sim/rtl/isp/ae_frame_stats.v) | 当前测光/高光及硬件统计除法；待由统一采集统计替代采集实例 |
| [rgb_gain_v1.v](C:/OneDrive/comp/Ti60F225_DemoBoard_v4/soc_hdmi_test/Ti60f225_soc_cam_hdmi_soc_sim/rtl/debayer/rgb_gain_v1.v) | 当前RAW增益与Bayer相位处理 |
| [hdmi_frame_histogram.v](C:/OneDrive/comp/Ti60F225_DemoBoard_v4/soc_hdmi_test/Ti60f225_soc_cam_hdmi_soc_sim/rtl/isp/hdmi_frame_histogram.v) | 后处理绘图直方图，不能直接代替CPU原始counts |
| [luma_tone_map.v](C:/OneDrive/comp/Ti60F225_DemoBoard_v4/soc_hdmi_test/Ti60f225_soc_cam_hdmi_soc_sim/rtl/isp/luma_tone_map.v) | 提亮像素处理；自动强度逻辑在auto_tone_lift.v |
| [main.c](C:/OneDrive/comp/Ti60F225_DemoBoard_v4/soc_hdmi_test/Ti60f225_soc_cam_hdmi_soc_sim/software/firmware/main.c) | 当前启动与阻塞式主循环；软件AE/AWB调度改造入口 |
| [soc_video_driver.c](C:/OneDrive/comp/Ti60F225_DemoBoard_v4/soc_hdmi_test/Ti60f225_soc_cam_hdmi_soc_sim/software/firmware/soc_video_driver.c) | OSD、摄像头和I²C包装；真实错误返回待完善 |
| [camera_init_table.h](C:/OneDrive/comp/Ti60F225_DemoBoard_v4/soc_hdmi_test/Ti60f225_soc_cam_hdmi_soc_sim/software/firmware/camera_init_table.h) | 165项初始化表 |

CPU程序/BSS/栈窗口为DDR `[0x1000,0x20000)`，栈 `[0x1f000,0x20000)`，SP初值0x20000；片上boot RAM为0xf9000000 / 4KiB；CPU scratch为0x01000000～0x01100000；视频三帧区 `[0x04000000,0x04a8c600)`。以app.ld及DDR地址文档为准，禁止新增缓冲与这些区域重叠。

## 7. 编译产物与验证边界

最新保存版本是 [RAW/RESIZE产物说明](C:/OneDrive/comp/Ti60F225_DemoBoard_v4/soc_hdmi_test/Ti60f225_soc_cam_hdmi_soc_sim/reports/raw_resize/README.md) 对应的版本，包含启动彩条。交接时重新计算文件哈希，确认如下：

| 产物（相对于工程根目录） | 大小 | SHA256 |
|---|---:|---|
| reports/raw_resize/raw_resize.bit | 2,592,444字节 | `180B337E29A0200219B5EF93EF56872501FE195CA72496010AF3059CC347C050` |
| reports/raw_resize/soc_video_app.elf | 87,580字节 | `D352E991DDB1770EDBF2EA4AB85FBFE3BA63CA8F7FFF9EC868B7A591D6B5D2E4` |
| reports/raw_resize/soc_video_app.bin | 4,054字节 | `80146433C75E870B070AF7F37F8DCAF8F44600E688CC50BB3D27F03926CE5A35` |

当前 `outflow/ti60f225_oob.bit` 与保存bit哈希一致，`software/firmware/build/soc_video_app.elf` 与保存ELF哈希一致。后续重新构建会覆盖outflow/build，不自动更新reports中保存的配套版本。

历史验证：

- 最新诊断版 Efinity map/debug/interface/PNR/PGM PASS；最小setup slack=0.274ns、hold=0.026ns，HDMI setup=7.279ns、core setup=3.926ns。记录在 `reports/raw_resize_compile.log` 和 `reports/raw_resize/timing.rpt`。
- 彩条逐像素时序/CDC切换、诊断异步事件/边界/复位/饱和、APB访问保护、完整RV32 ELF normal/id_retry/no_ack/ddr_corrupt/timer_wrap与trap历史回归PASS。证据在reports/raw_resize及reports/simulation。
- 历史较早3898字节固件曾完成实板bit烧录、GDB下载与逐字节DDR读回、UART初始化日志、摄像头CD6B初始化、DDR scratch与OSD ACK；日志在reports/hardware_debug。不能把这份早期硬件证据当作新AE/AWB功能的验证。
- 彩条和诊断版本在本agent记录的下载尝试中未成功烧录，之后用户报告实际RAW/RESIZE约12。可以记录为用户观测；缺少本agent对当前板上bit/ELF哈希与完整新版本实板流程的独立确认。无需为解决文档状态差异立即访问硬件。
- 受保护Sapphire CPU RTL不能由Icarus直接解析；验证采用真实ELF指令模型、AXI/APB BFM与Efinity综合，模型不涵盖真实cache、物理MIPI/DDR/I²C时序。不能将这些模型PASS表述为全系统物理仿真PASS。

本次交接任务只做文件/代码/文档核对及保存产物哈希验证，没有重新运行RTL回归、Efinity编译或硬件测试。

## 8. 构建与回归入口

在工程根目录运行。下面均为软件/仿真/编译操作，不访问板卡；依据修改范围选择回归，无需每次文档修改重跑整个工程。

```powershell
Set-Location 'C:/OneDrive/comp/Ti60F225_DemoBoard_v4/soc_hdmi_test/Ti60f225_soc_cam_hdmi_soc_sim'
python tools/check_rtl_config.py
python tools/check_firmware_config.py
python tools/build_firmware.py
python tools/test_firmware_runtime.py
python tools/test_firmware_driver.py
python tools/test_hdmi_startup.py
python tools/test_video_frame_diagnostics.py
python tools/run_rtl_checks.py
python tools/test_resize_checks.py
python tools/test_resize.py
python tools/test_video_dma_shared.py
git diff --check
```

完整FPGA编译：

```powershell
& 'C:/Efinity/2026.1/bin/efx_run.bat' ti60f225_cam_hdmi.xml --flow compile --timeout 1200
```

工具路径：RISC-V工具链 `C:/Efinity/efinity-riscv-ide-2026.1/toolchain/bin`；Icarus `C:/iverilog/bin/iverilog.exe`、`vvp.exe`。固件构建可用SOC_RISCV_TOOLCHAIN覆盖工具链，仿真依赖见tools/firmware_sim_requirements.txt。阅读PDF需遵循适用PDF skill；历史提取环境Python为 `C:/Users/Goodmann/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe`。

Efinity曾自动重写ti60f225_cam_hdmi.xml格式；不要把工具重排误认为必要实现改动，也不要无条件git restore覆盖用户真正的XML修改。此前新增彩条/诊断通过top include接入。`work/final_hardware_check.py` 等历史脚本含3898字节/旧地址假设，不直接复用。

## 9. 接手后的建议顺序

1. 阅读最新统一方案并重新核对Git状态；保留已完成彩条、诊断、校准值、IDE与DDR地址协议。
2. 若用户要求实现，先做单APB框架和兼容映射，检查译码覆盖0x1ff且无别名，再做统一采集统计与同帧标量快照。接口完成前不要让CPU访问规划寄存器。
3. 完善真实I²C错误处理和合作式主循环，实施软件AE；真实VTS未读取前不预设曝光上限，也不自动改模式追求30FPS。
4. 完成gain/筛选参数帧边界提交与配置标签对齐，然后实施软件AWB及AE/AWB协调。建立独立参考与有意义的边界/异步/错误回归。
5. 在统一统计模块中加入64bin与完整冻结META，验证同bin双像素写入冲突、sum(bin)=AE_SAMPLE_COUNT、冻结期间新帧继续、原始counts与绘图高度用途分离。
6. 完成所需回归、Efinity资源/时序评估，保存新的配套bit/ELF与报告，更新CAPS、集成日志和旧文档中的过时描述。
7. 只有用户重新要求烧录/实板测试后，才按README_PROGRAMMING执行硬件操作并记录版本、日志与验证范围。

最重要的未完成事项：**软件AE未开启、AWB未实现、统一APB与统一采集统计尚处方案阶段；当前RAW/RESIZE约12的传感器侧原因也未确定。**
