# 统一视频 APB、采集统计与软件 AE/AWB 实现

更新：2026-10-09。用户已要求实施，本文描述实际代码；`VIDEO_APB_CONTROL_PLAN.md` 保留详细设计背景。用户实板已恢复RAW/RESIZE30FPS并确认AE工作；当前针对小高亮光源抽动的调整已通过模型回归，尚待加载实板。不修改传感器 VTS、PLL 或模拟增益。

2026-10-09 补充：持续彩条已定位并修复固件ACK语义错误（RX_ACK读后清除、最终master NACK监听及有界总线恢复），实际导入Sapphire I²C RTL按位从机仿真和RV32启动/3A回归PASS，实板已恢复采集与AE/AWB更新。ACK修复归档在`reports/software_3a_i2c_fix/`，后续AE调节见`reports/software_3a_ae_tuning/`。当前推荐SoC清理新bit与配套固件在`reports/soc_cleanup/`，最新调整实板效果待复查。

## 接入与兼容

唯一 SoC APB 入口为 `video_apb_ctrl.sv`，基址 `0xf8100000`。Sapphire settings 的 APBSlave0_Size=65536，地址输出16位，扩展不需重新生成 SoC。完整16位译码，非对齐、未定义地址及只读写入 PSLVERR；SETUP 无副作用。`osd_apb_regs` 是内部兼容 bank，0x000～0x030 协议不变。VERSION=0x00010000，CAPS=0x000001ff。

寄存器与方案表对应：0x034～0x06c 版本/双组提交/gain/tone，0x080～0x094 手动 lift/显示统计，0x0c0～0x0ec 同帧统计，0x100～0x12c 原始 Y 直方图，0x140～0x160 诊断，0x180～0x1a0 RAW AWB。未分配地址拒绝访问。LIFT_SHADOW.bit1 请求自动提亮会被拒绝；本期只支持固定手动提亮。软件寄存器常量见 `software/firmware/video_regs.h`。

CAPTURE 和 DISPLAY 各有 SHADOW/pending/ACTIVE。APPLY 在 core 锁住 payload，目标时钟域在 RAW VS 下降沿 / CVO VS 上升沿整组生效，返回 apply ACK 后才更新 core ACTIVE 镜像和版本并清 BUSY。摄像头无帧时采集提交保持 BUSY；超时不取消硬件请求。BUSY 时重复提交拒绝，改写 SHADOW 不覆盖在途请求。

默认保持 R=0x168、G=0x100、B=0x1a9；tone enable=1、两强度32；lift enable=1、manual32；hist 显示关闭。旧硬件AE/I²C链已从顶层移除，CPU独占摄像头物理I²C，开漏输出保持write=0驱动低、write=1释放。

2026-10-09 SoC清理：移除旧AE及其统计/状态CDC、旧I²C初始化链和所有权mux、固定文字OSD、无消费者的显示/OSD状态mailbox、冗余osd_control_mailbox与旧控制声明。保留历史模块文件及独立测试，不再列入当前工程构建。直方图直接使用display_config已提交到HDMI域的配置；动态文字保留双缓冲COMMIT/ACK。修复en2遗漏同步，并将文字开关锁存在下一VS，无需额外COMMIT。auto_tone_lift被等价手动限幅替代，显示亮度统计仍供APB诊断。新硬件编译与验证见`reports/soc_cleanup/README.md`。

## 统一采集统计与精度

实际 gearbox 将 CSI RAW10 的低两位丢弃，再输出每拍两个 RAW8。本实现直接使用增益前 RAW8，AWB_SUM 的单位是 RAW8；没有重新构造 RAW10。SOURCE=1 表示 AE 为 gain 后 RGB、AWB 为 gain 前 Bayer RAW，精度以本文为准。RAW8 与 RAW10 的比例公式相同，但不声称保存了10位精度。

`capture_frame_stats.sv` 对 RGB pair 列0,8,16…及行0,8,16…采两个像素；Y=(R+2G+B)/4。亮度和、样本数、任一 RGB 通道高光数以及64个 Y[7:2] bin 使用完全相同的样本。1080p 每帧32400个 AE 样本。双像素同 bin 加2、不同 bin 各加1；读计数与加写分拍，采样间隔8拍，避免读写冲突。源 histogram 为16位，溢出拒绝有效帧。

AWB 抽取 pair 列0,8,16…，使用行(0,1),(8,9)…的 BGGR 完整2×2单元：偶行 low=B/high=Gr，奇行 low=Gb/high=R。只缓存120个抽样列的上一行。1080p 每帧16200个候选前单元；筛选后 R/B 各 N 样本，G 有2N样本，32位 SUM 无溢出。四通道均满足 dark_min <= RAW8 < sat_max 才接受；默认8/248。可选中性色用生效 gain 的未饱和乘积比较 max×256 <= min×ratio，默认关闭。滤波乘积/最大最小值/比例比较流水化。

RAW/RGB 独立检查1920×1080行宽和行数。RAW 配置版本随 gain(1拍)+line_buffer(2拍)+raw_to_rgb VS(2拍)共5拍传递，旧 RGB 帧尾不会误用新 RAW 帧版本。两路同帧号、同版本且尺寸合法后整体发布。没有 AWB 候选时仍发布 AE_VALID。采集或缩放故障不发布新有效统计。采集统计移除了除法，CPU 计算均值/比例；显示侧 meter 和绘图 histogram 保留原用途。

384位标量经 bundled-data 握手 mailbox 跨域，payload 保持至确认。core 同拍更新整个包、64位到达 tick 和32位发布序号。软件 SEQ→全部数据→SEQ 校验，序号0在回绕后仍有效。源 backpressure 保留在途包并锁存 overrun；过期/不匹配版本不用于追调。

ACQUIRE 在源域等待有效完整帧，冻结64bin及同帧14项 META，通过78个逐项握手包复制到 core 缓存，最后置 LOCKED_VALID。每个包只有39位，不对大直方图逐位同步。APB 通过 INDEX/DATA 读取 core 寄存器缓存，无 wait state；没有有效快照时 DATA 返回 PSLVERR。锁定期间新统计继续，RELEASE 才允许下一次 ACQUIRE。冻结 TIME 为最后一项到达 core 的时间。`video_hist_poll` 非阻塞读取，每次最多4项；标准3A使用实时标量；`app_hist_enable` 默认0，IDE设1后合作式服务读取快照，查看 `app_hist` 及 updates/errors 计数，不增加默认控制延迟。

## 软件控制与调度

启动探测 VERSION/CAPS/SOURCE，读取 ID、VTS(320e[6:0]/320f)、曝光(3e00/01/02)。非法 VTS 或总线错误禁用3A。AE 范围4～2×VTS−11半行。基础亮度目标96；高光超过10‰后，每增加4‰将目标降低1，最低72，避免小光源触发无条件减曝光与平均亮度控制冲突。高光并非硬性限制，持续亮光源可以保持饱和以兼顾主体亮度。初始化曝光越界时首次有效测光收回合法范围。

亮度误差≥24用比例修正、单次限定0.5～2倍；误差12～23用半幅修正，5～11用四分之一修正。误差≤4进入保持，保持后误差≤8不动；细调需要连续3份有效、已稳定统计在同一方向越界，明显光照变化立即进行粗调。统计依然等待曝光确认/配置版本匹配，不缩短传感器生效保护。UART增加goal与hold，app_3a包含ae_goal/ae_held/ae_direction/ae_streak。此滞回抑制测光噪声，不是50/60Hz曝光量化防闪烁。

AE 决策先排队，观察下一次真实 CSI 帧事件后写入。每次读取曝光保留字段，Group Hold 3812=00→三字段→3812=30，并读回确认。任何中间失败仍尝试释放 Hold，未确认的曝光不写入软件确认值，禁用新增3A操作。Sapphire BSP 包装检查每字节 RX_ACK VALID/NACK、START/STOP dropped 及超时：事务预算5ms，异常 STOP 清理另有5ms上限，超时 DROP；不再无条件成功。模型通过不代表物理总线时序已验证。

RX_ACK.VALID 是读后清除，LISTEN 写入不会清除它。发送前先 drain，读取最后一个数据字节之前关闭 ACK 监听，避免 master NACK 残留背压。初始化/重试检测总线状态，必要时有界 DROP/RECOVER；RECOVER 自带 STOP，不能在 idle 补发 STOP。恢复失败不进入初始化成功路径。

成功写曝光后同时记录实际 CSI 序号和最近完整采集帧号。读取 3802[1:0] 的 Group Hold 帧延迟，两者都前进至少 3+delay 帧后才读回确认并更新 exposure/ae_updates，随后允许继续控制；写入请求暂存在 pending_exposure。释放 Hold 后不立即用旧读回判错。这是对手册 N+2 的保守等待，避免将统计发布序号或统计到达时刻当作曝光生效时刻。2秒不能确认则禁用控制。摄像头/gearbox pipeline 延迟仍需实板确认；保守等待可能多等一帧。

AWB 默认 AUTO，目标 round(256×G_SUM/(2×R_SUM/B_SUM))，G固定256。有效候选至少64单元且占总单元至少5%；零分母或不足样本保持最后生效值。目标范围128～1024，约1/4平滑，死区3，单次gain步幅16，至少间隔4采集帧提交。采用 core 已 ACK 的 ACTIVE 值，等待新 CFG 对应统计后再计算。中性色筛选默认不自动开启；黑电平软件补偿未标定，当前按残余偏置可忽略处理，实板应以遮光和灰卡检查。

`camera_3a` 优先服务需要调整的 AE；等待曝光时暂停 AWB，等待 gain apply 和新版本统计时暂停 AE。一次快照最多触发一个回路，AWB 微调不能饿死 AE。`app_awb_mode` 可在 IDE 改为0固定校准、1自动、2锁定当前值。算法参数在 C 文件内，运行状态、读回 VTS/曝光、均值、高光比例、更新/错误计数通过 `app_3a` 查看，UART每秒也输出3A状态与参数。灰度世界无法可靠区分单色物体与光源偏色，实板需灰/白卡、两种光源及单色场景测试。

主循环约1ms检查一次3A；I²C事务和每秒 UART 文本仍有有限执行时间，不承诺硬实时1ms延迟。启动 DDR scratch 保留，取消每秒64KiB阻塞压测；运行期 OSD 用 submit/poll，250ms超时不阻塞3A。摄像头初始化失败时仍每秒重试；故障时报告状态并保持最后确认参数，不擅自重置整条视频链路。

状态值：OFF=0，READY=1，EXPOSURE_WAIT=2，GAIN_WAIT=3，NO_STATS=4，BUS_ERROR=5，CONFIG_TIMEOUT=6，CAPTURE_FAULT=7。超过1秒无新有效统计停止新决策；capture/resize故障、I²C失败或gain apply超过2秒禁用3A，需明确恢复/重新初始化。

## 验证入口

```powershell
python tools/build_firmware.py
python tools/test_video_3a.py
python tools/test_video_3a.py --full
python tools/test_camera_3a_runtime.py
python tools/test_firmware_runtime.py
python tools/test_sapphire_i2c_ack.py
python tools/test_hdmi_startup.py
python tools/test_video_frame_diagnostics.py
python tools/test_soc_cleanup.py
python tools/run_rtl_checks.py
python tools/test_resize_checks.py
python tools/test_resize.py
python tools/test_video_dma_shared.py
python tools/check_rtl_config.py
python tools/check_firmware_config.py
git diff --check
```

原FPGA编译记录见`reports/software_3a/README.md`；AE调整见`reports/software_3a_ae_tuning/README.md`；最新SoC清理bit、固件、时序与回归记录见`reports/soc_cleanup/README.md`。既有固件实板已确认采集/AE/AWB更新，最新防抽动及文字开关效果尚待实板确认；不能由模型收敛推断实际效果。
