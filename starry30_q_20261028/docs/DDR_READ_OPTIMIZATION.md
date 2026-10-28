# DDR 等待诊断与显示读优化

工作区 `Ti60f225_soc_cam_hdmi_style_demo`，分支 `codex/monet-style-demo`；本次起点为 `e8ff563`（固定显示读优先）。按照用户要求，先增加等待计数，再缓冲显示返回，最后修改读仲裁。网络、权重和训练结果未改变，原 `Ti60f225_soc_cam_hdmi_soc_sim` 工程未修改。本轮不连接或操作开发板。

## 原因与实现

内层 CNN/显示桥和外层 CPU/视频桥各保持一个读突发在途。原显示 reader 将 128 位 DDR beat 慢慢拆成四个像素，pixel FIFO 满时又进一步停住，因此 `RREADY` 反压把共享读通道占住。新增逻辑读主机不会增加物理 DDR 带宽，先缩短这个占用更划算。

`style_display_beats.sv` 提供 32 beat 同步 RAM 和一个弹性输出寄存器；存储每 beat 的四个 RGB24、RRESP、RLAST，共 99 位。无用的 XBGR padding 字节不存储，输出时补零。可以在像素消费者停止时接收完整最大突发，再按原 reader 的速率拆包。边界、响应错误、RLAST 校验仍由原 reader 处理。reader 吃完当前突发后才发下一突发，未增加 outstanding。

显示 pixel FIFO 从 1024×60 缩为 512×60，以部分抵消 beat 缓冲的 RAM 消耗。Efinity 实际映射：beat 缓冲 5 RAM，pixel FIFO 3 RAM；显示部分合计 8 RAM。不能以有效 bit 数简单估计 FPGA RAM 块数。

为回收布线所需的逻辑，系数下载 FIFO 和 CNN AR/AW 控制 FIFO 从 16 项缩为 4 项，继续保留读侧弹性输出寄存器。APB 写系数时受 `PREADY` 反压，开始任务前仍等待所有系数确认；行 DMA 每方向只有一个事务在途，地址队列不需要预留 16 项。W/R 数据 FIFO 深度保持 16。这一步不增加 outstanding，不改变模型或 MAC 引擎。综合相比首版优化少 1379 FF、593 LUT。

`style_display.read_urgent` 在显示有效且任一条件成立时拉高：写域 pixel FIFO 水位低于 256、当前行任务年龄达到 1600 个 100MHz 周期（16us）、行请求尚待处理。请求领先可见行约 25.7us。水位使用同步到写域的 Gray 读指针，保守估计、带同步延迟，并且不包含读域弹性输出字。

动态仲裁在突发边界执行：urgent 显示先读；数据充足时 round-robin。CNN 请求持续有效时，最多被三个新显示突发绕过，然后分配给 CNN。已经在途的突发不能被抢占。这是**突发次数上限**；DDR 不返回、外层等待或接收端停顿仍可延长时间，不能给出无条件的微秒等待上限。外层 CPU/视频公平仲裁未改动。

## 计数与日志

APB 基址 `0xf8100200`。`0x54` bit0 冻结、bit1 单拍清零；写 1 冻结，写 0 恢复，写 2 清零并恢复，写 3 清零并保持冻结。冻结/清零不改变 AXI 事务追踪状态。流模式使能后累计，100MHz、32 位模加计数。1 秒日志间隔内可用无符号减法处理回绕；超过约 42.95 秒不能恢复准确的时间差。计数条件有重叠，百分比不能相加当成时间分区。

| 偏移 | UART 字段 | 条件/含义 |
|---|---|---|
| 0x58 | T | 测量窗口总周期 |
| 0x5c | AR | CNN ARVALID 且无 ARREADY，内层入口等仲裁 |
| 0x60 | DOWN | 内层下游 ARVALID 且无 ARREADY，包括外层桥等待 |
| 0x64 | RGAP | CNN AR 被接受后，RREADY 且无 RVALID；包括下游延迟 |
| 0x68 | RBP | CNN RVALID 且无 RREADY |
| 0x6c | DBP | 显示 RVALID 且无 RREADY |
| 0x70 | AW | CNN AWVALID 且无 AWREADY |
| 0x74 | W | CNN WVALID 且无 WREADY |
| 0x78 | B | CNN WLAST 已握手后，等待 BVALID |
| 0x7c | IDLE | 网络可接受任务，任务间空闲 |
| 0x80 | RB | CNN 读 beat 握手次数 |
| 0x84 | DRB | 显示读 beat 握手次数 |

`DOWN`、`RGAP` 不是独立 PHY 的精确等待计数，也不是只有 DRAM 刷新/行切换。`B` 不把接收端拒收一个已有效 BVALID 算作 DDR 等返回。本轮统计 CNN 写通道；没有单独增加相机写通道计数。

另有每次任务的 148.5MHz 快照：`0xa8` 为 READWAIT/SKIPWAIT 周期，`0xac` 为 core busy 周期。完成 toggle 与总周期一同发布，IRQ 后读取。`RPMS`/`CPMS` 是快照除以 148500 后的整数毫秒；core busy 包含输出背压，不能当作纯 MAC 有效计算时间。两种时钟的计数不能直接相加。

固件每秒先冻结→读取 12 个计数→恢复，再打印：

```text
DDR100M T ... AR ... DOWN ... RGAP ... RBP ... DBP ... AW ... W ... B ... IDLE ... RB ... DRB ... RPMS ... CPMS ...
```

AR 到 IDLE 是相对 T 的整数百分比，RB/DRB 是 beat 次数。原 `MONET CAP/NN/DISP/DROP/MS/ERR` 日志和 OSD 保留。CAP 指进入抓帧队列的帧，队列满时会丢弃输入，不能据此判断摄像头输出只有 CAP fps。

## 三种模式对照仿真

实际 `style_video_system`，同一随机 DDR 种子，显示预置 slot0 的完整原画/结果，640×48 CNN 任务位于 slot1，同时一帧密集 1080p 相机流抓入 slot2。三个测试均核验所有 CNN 输出与整数参考一致、307200 个抓帧像素正确、显示左右 RGB 正确、欠载 0。

| 模式 | CNN 总周期 | 读阶段周期 | core busy 周期 | CNN AR 等待/窗口 | 显示 RREADY 反压 |
|---|---:|---:|---:|---:|---:|
| 固定显示优先、无 beat 缓冲 | 2269633 | 1782318 | 477327 | 910136 / 1528382（59.55%） | 594691 |
| 固定显示优先、有 beat 缓冲 | 1029441 | 538867 | 480442 | 72624 / 693237（10.48%） | 0 |
| 按需仲裁、有 beat 缓冲 | 1029441 | 538867 | 480442 | 72624 / 693237（10.48%） | 0 |

同一短任务耗时从 15.2837ms 降到 6.9323ms，周期减少 54.64%，加速 2.205 倍。这个收益来自显示 beat 缓冲；该刺激下按需仲裁未带来额外周期改善，其价值由独立 urgent/非 urgent 仲裁测试中的公平保证证实。

每种 CNN 都读取 103680 beat、相机写入 76800 beat。旧版任务持续更久，因此累计显示像素/读 beat 更多；不能把整个测量窗口的显示总流量直接比较为带宽降幅。短帧结果不外推成完整 VGA 或实板 FPS。

最终源码的完整 640×480 并发仿真通过：10242677 个 CNN 周期，68.974ms，对应行为模型下 14.498 task fps。CNN 全帧与整数 oracle 一致，307200 个抓帧像素正确，四帧显示共 2457600 个像素正确，欠载 0。控制 FIFO 缩小前后任务周期一致；最终源码短帧复测也保持 1029441 周期。它包含一帧密集抓帧和持续显示，不是持续 30fps 抓帧或外层 CPU/DDR PHY 的板上测量，也没有证明 15fps 验收目标。发布包记录编译前 RTL 哈希并核对当前源码匹配。

完整帧测量窗口 6897433 个 100MHz 周期：CNN AR 等待 765790（11.10%），CNN 返回间隙 1618994（23.47%），CNN W 等待 464025（6.73%），显示/CNN RREADY 反压均为 0。网络读阶段 5447882 周期（36.686ms），core busy 4713227 周期（31.739ms）；core busy 含输出背压。CNN 读取 1036800 beat，显示读取 614400 beat。这说明本场景解除显示接收反压后，下一项值得评估的是读阶段与计算/输出阶段的重叠；不能只再增加仲裁逻辑就承诺更高帧率。

## 最终资源和时序

Efinity 2026.1.132，Ti60F225 I3，TIMING_3、seed 0；map/interface/pnr/pgm 均通过，只生成配置文件。首版新增逻辑占用 XLR 60615/60800，TIMING_3 布线因拥塞失败；CONGESTION_3 尝试长期未收敛后停止。控制 FIFO 压缩后恢复原 TIMING_3 配置，成功完成布局布线。

| 项目 | 最终结果 |
|---|---:|
| 布局后 XLR | 58665 / 60800（96.49%） |
| RAM10/DPRAM10 合计 | 256 / 256（100%） |
| DSP | 140 / 160（87.50%） |
| 综合 LUT4 | 38283 |
| 综合 FF | 27441 |
| CNN 148.5MHz setup slack | +0.502ns |
| 系统 100MHz setup slack | +2.243ns |
| 最小已报告 hold slack | +0.026ns |
| Synchronizer 报告 | No warnings |

XLR 比首版优化回收 1950 个，但 RAM 仍无剩余；不能直接增加新的行缓存。

## 验证与复现

Icarus 运行实际新 RTL，Unicorn 执行实际 RV32 ELF；DDR、UART 等是行为模型。未覆盖厂商物理链路和外层 CPU 流量的完整 VGA 性能，未测量新版本板上 FPS。

```powershell
python tools/test_style_ddr_units.py
python tools/build_firmware.py
python tools/test_style_ddr_firmware.py
python tools/run_style_checks.py --system
python tools/test_style_system.py --variant baseline
python tools/test_style_system.py --variant buffer
python tools/test_style_system.py --variant adaptive --tag controls4
python tools/test_style_system.py --variant adaptive --height 480 --tag controls4
```

完整 VGA 集成仿真需较长时间；脚本输出层号，退出码为 0 且完整输出对拍通过才算成功。新鲜工作区缺失输入时，脚本自动生成整数 oracle 和 APB 系数加载模板。

beat 单测覆盖消费者停住时接收完整 32-beat、512 个包、随机背压、RRESP/RLAST、reset；四项控制 FIFO 单测覆盖 40/45 位双向非同源时钟、满时反压、复位丢弃和各 1000 字顺序；计数单测覆盖精确事件、freeze/clear/disable/wrap，以及冻结/清零期间持续追踪事务；仲裁单测覆盖 180 个读请求、urgent 最多三次绕过、非 urgent 公平及 ID 路由。小图全网络、APB/CDC/IRQ、AXI 错误与运行中复位、两级桥、完整抓帧和三帧显示恢复也必须通过。

布局布线目录 `outflow_style_ddr_opt`，工作目录 `work_style_ddr_opt`，后续配置文件与 ELF 发布到 `reports/style_demo/release_ddr_opt`。旧版本发布目录保持原用途。固件/bit 必须一起更新，否则旧固件不输出诊断或旧硬件不提供寄存器。

Efinity 2026.1 使用工程中的 TIMING_3、seed 0 设置；各阶段命令分别如下。最后一条仅生成配置文件，没有烧录动作。打包脚本要求四个阶段和完整 VGA 集成仿真均通过。本次最终源码重测添加 `--tag controls4`，单独保存在 `adaptive_controls4` 和 `adaptive_vga480_controls4`，并记录编译前 RTL 哈希；打包时核对源码未改变。

```powershell
efx_run.bat ti60f225_cam_hdmi.xml --flow map --output_dir outflow_style_ddr_opt --work_dir work_style_ddr_opt
efx_run.bat ti60f225_cam_hdmi.xml --flow interface --output_dir outflow_style_ddr_opt --work_dir work_style_ddr_opt
efx_run.bat ti60f225_cam_hdmi.xml --flow pnr --output_dir outflow_style_ddr_opt --work_dir work_style_ddr_opt
efx_run.bat ti60f225_cam_hdmi.xml --flow pgm --output_dir outflow_style_ddr_opt --work_dir work_style_ddr_opt
python tools/package_style_ddr_optimization.py
```

## 上板与后续选择

连接开发板后，在相同分辨率/输入帧率/场景下采集至少 30 秒 UART，并同时检查 CAP/NN/MS、DROP、显示欠载和所有 AXI/DMA 错误。先比较 AR、DBP，再观察 RGAP、AW/W、RPMS/CPMS；任何显示欠载都需要重新评估水位、行期限和三突发限额。板上计数有了数据才选择下一项。

若仍主要是 AR 等待，先细调仲裁和行请求时机；若主要是 RGAP/读阶段，则评估有限预取或小范围读算重叠。若 core busy 高，还要区分计算与输出背压。层间融合要明确消掉哪些 DDR 往返以及新增存储；不能只按理论 MAC 吞吐估算收益。

本版资源接近器件容量，直接加双行缓存、多 outstanding、更多 AXI 主机都需要先回收 RAM/XLR，再做时序和显示连续性验证。本轮在上述前三项闭环后停止，不改变网络结构或直接加入融合。

按实际 graph/program 的宽度与通道，最大预取输入行为 `dec.1` 的 320×24 INT8，共 7680 bytes；仅按 10Kbit 容量估计也至少需要 6 RAM10，实际端口/宽度映射可能更多。现有三行缓存不能在计算尚读该行时被覆盖，残差 skip 另有读取需求。因此优先评估能否复用已有行缓存生命周期、缩小局部层间读写或回收其它 RAM；不能直接承诺双缓冲或多 outstanding 的收益。
