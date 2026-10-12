# 莫奈实时风格 Demo 实现与验收

DDR 等待诊断、显示突发缓冲与按需仲裁的后续版本见 [DDR_READ_OPTIMIZATION.md](DDR_READ_OPTIMIZATION.md)。本页的 `outflow_style_final`、资源和周期表保留原发布版本结果；新版本使用独立的 `outflow_style_ddr_opt` 与 `reports/style_demo/release_ddr_opt`。

独立分支：`codex/monet-style-demo`。独立工作区：`C:/OneDrive/comp/Ti60F225_DemoBoard_v4/soc_hdmi_test/Ti60f225_soc_cam_hdmi_style_demo`，可打开根目录 `MonetStyleDemo.code-workspace`。基线提交 `85439b8` 保存已有 P1/P2/P3；原工程、原数据集不修改。

已完成训练、INT8 导出、共享 RTL 引擎、APB/中断驱动与相机视频链路集成。配置文件已生成。无开发板连接，本记录不把仿真或时序报告称作实板测量。

## 训练结果

| 项目 | 结果 |
|---|---:|
| 训练参数 | 8251 |
| Conv / BN | 23 / 22 |
| 有效模型载荷 | 11056 bytes |
| 银行化系数镜像 | 24576 bytes |
| 保留 test 照片评估 | 64 张 |
| 原图平均风格 Gram MSE | 0.00020175955 |
| 整数网络平均风格 Gram MSE | 0.00016025477 |
| 平均风格误差下降 | 20.57% |
| 整数 vs QAT 平均 PSNR | 41.15 dB |
| 整数 vs FP 学生平均 PSNR | 33.74 dB |
| 整数 vs QAT 平均 MAE | 1.25 RGB LSB |

选定模型为 `ml/style_transfer/artifacts/student_qat.pt`，checkpoint SHA256 `320aa954ef74893f5f8c314010dde797866378591fb5b849d7fda5a427c19b70`；模型载荷 SHA256 `321b9e798d576d03c67882225748763d7f0d1288c8e8342e2241b605a20fd5dc`。

数据实际为莫奈画作/照片非配对集合。最终按近似图分组划分，保留 test，八张 trainA 绘画作为 Gram 目标。详细数据和训练路线见 `STYLE_TRANSFER_FPGA_PLAN.md`、`ml/style_transfer/README.md`。部分 `trainB/` 文件因近似组跨原始边界被保留为 test，最终 split 以 manifest 为准。

画质是温和的色调/纹理简化，不承诺每幅照片都有明显莫奈笔触。部分 test 照片的风格距离变大；20.57% 是均值改善。没有配对艺术真值，PSNR 衡量部署与参考网络的一致性，不代表艺术质量。4 像素合成平移有效区域误差为 0，仅说明这组平移等变测试，不代表真实视频无闪烁。

比较图是离线整数参考输出：`style_demo_results/vga_demo.png`、`heldout_comparison.png`。完整 VGA RTL 的随机输入对拍单独记录，不能把离线图片称作实板 HDMI 截图。

## 实际硬件行为

相机 RGB 双像素流中心裁剪 1280×960，2×2 平均后存储 640×480 XBGR8888。23 层由共享 96 路 INT8 MAC、显式 BN、ReLU/残差、nearest 上采样执行。中间层逐层经 DDR 读写；未实现原设想的多层融合。

CNN 148.5MHz、DDR/APB 100MHz、HDMI 74.25MHz。所有 AXI 通道使用异步 FIFO。六个成对 raw/result 槽保留所有权：抓帧 B 响应完成后入 READY FIFO，FIFO 顺序推理，最新完成帧在显示安全点交换。左右原画/结果使用同一 slot。队列满时丢帧并计数；显示固定 720p60，上下 120 行黑边，缺失像素变黑且 HS/VS 不停止。

原 CSI、Debayer、软件 3A、Sapphire、DDR、OSD、启动彩条和受保护源保留。CPU/CNN/video 通过两级 AXI 仲裁共享 DDR，外层先保存完整本地 ID，再在返回时恢复内层所有权。

## 综合、布局布线

Efinity 2026.1.132，Ti60F225，I3 timing model。最终结果目录 `outflow_style_final`；发布副本在 `reports/style_demo/release`。

| 资源/时序 | 实际结果 |
|---|---:|
| 布局后 XLR | 59478 / 60800（97.83%） |
| RAM10/DPRAM10 合计 | 254 / 256（99.22%） |
| DSP | 140 / 160（87.50%） |
| 综合 LUT4 | 37837 |
| 综合 FF | 28282 |
| CNN 148.5MHz setup slack | +0.362ns |
| 系统 100MHz setup slack | +1.970ns |
| 已报告最小 hold slack | +0.026ns |
| Synchronizer 报告 | No warnings |
| 配置文件生成 | PASS；未 program/烧录 |

RAM 仅余 2 块、XLR 余 1322，余量很小；当前结果支持此单风格 Demo，不据此承诺再加入双风格并存或更大网络。原引擎先遇到 336 RAM 超预算和 XLR 打包超容量，已通过单读系数 RAM、按宽度/通道拆行缓存、抓帧 BRAM、浅 FIFO 寄存器化、显示 FIFO 缩小、范围证明缩位和 FIFO 帧调度完成压缩。

## 已执行仿真

| 验证 | 覆盖 |
|---|---|
| MAC | 4989 输入包、2002 输出，随机停顿，负 gain、shift0、饱和、正负半值 |
| 所有训练层逐行 | 23 层、192 行、2976 像素与 NumPy 独立整数参考一致 |
| 完整小图 | 32×24，完整网络 DDR 写回逐字一致，随机 AXI 停顿 |
| 完整 VGA 推理 | 640×480 全部 RGB 逐字一致，9,056,056 周期；随机停顿 DDR |
| 完整系数编程 | 系数 RAM 初始清零，全部 6144 个 APB word 加载后完整 RGB 对拍一致 |
| APB / CDC / IRQ | unrelated 100/148.5MHz、提交 ACK、busy 配置拒绝、IRQ/W1C |
| 错误/复位 | RRESP/BRESP 错误完成；运行中异步复位后重新执行完整网络 |
| 两级 DDR 仲裁 | CPU/CNN/video 同时 150 写 +150 读，完整 ID 恢复、数据、无饿死 |
| 队列/所有权 | 六槽满队列丢帧、原画/结果配对、显示安全点、错误回收 |
| 完整抓帧 | 1080p→VGA，307200 个正确像素、2400 bursts，跨钟 FIFO 无溢出 |
| HDMI | 三帧完整 1650×750 时序、两侧精确 RGB、换槽；DDR 饥饿黑屏并恢复 |
| CNN/抓帧/显示并发 | 实际集成 RTL：640×48 推理逐字一致，完整摄像头 VGA 写入，339,200 个显示像素正确，欠载 0 |
| 实际 RV32 ELF | 启动、全权重、自测、PLIC claim/release、中断保存/恢复及 mret、自测坏像素拒绝、重新加载 |
| 实际 RV32 OSD/UART | 按实际时间计算 CAP/NN FPS、单独 DISP60、累计 DROP、耗时、32 位计数回绕 |
| 原功能回归 | P1/P2/P3 RAM/OSD、启动彩条、软件 AE/AWB、105 文件配置/保护块检查 |

RV32 验证运行实际编译 ELF，使用 Unicorn 指令模拟和外设模型；不把它称作 Sapphire RTL/缓存/PLIC 硅验证。网络/视频/AXI 测试运行实际新 RTL，DDR 模型随机停顿但不是厂商 DDR PHY 的精确周期模型。没有验证受保护 MIPI/DDR/HDMI 编码器的实板物理层。

完整 640×480 VGA RTL 已逐字对拍通过：9,056,056 个 CNN 周期，148.5MHz 下为 60.984ms，对应 16.398fps；33,720 个读事务和 29,880 个写事务。测试采用随机停顿 DDR 行为模型，没有其它 DDR 主机竞争。这是完整帧仿真结果，不能把 720p60 的重复显示算成 NN60fps，也不保证处理 30fps 的全部输入。

实际 `style_video_system` 并发压力测试预置已完成的显示槽 0，手动提交 640×48 网络任务到槽 1，密集 1080p 摄像头流抓入槽 2，同时使用真实 crop/FIFO/抓帧/显示/CNN/内层 AXI 桥。网络 1,298,011 周期，即 8.741ms；摄像头 76,800 个 128 位 beat、307,200 个 VGA 像素，显示 339,200 个正确像素，显示欠载 0。摄像头流仅 40 个 pair-clock 行间隔，负载高于正常 30fps，未加入外层 CPU 或厂商 DDR PHY。按网络高度线性缩放约 11.44fps，只是该短帧压力场景的估计，**没有证明并发完整 VGA 满足 15fps**。DDR 竞争对吞吐有明显影响，上板后必须实测；本版本以显示连续、可计数丢帧的单风格 Demo 为交付范围。

## 本地运行与后续板上验收

```powershell
# 在本独立工作区中，使用已检测的 Python；Icarus 默认 C:/iverilog/bin。
python tools/run_style_checks.py --vga --system
# RV32 测试依赖：tools/firmware_sim_requirements.txt，可放到 work/sim_deps。
# Efinity 构建只生成配置文件，以下没有 program 操作。
C:/Efinity/2026.1/bin/efx_run.bat ti60f225_cam_hdmi.xml --flow map --output_dir outflow_style_final --work_dir work_style_final
C:/Efinity/2026.1/bin/efx_run.bat ti60f225_cam_hdmi.xml --flow interface --output_dir outflow_style_final --work_dir work_style_final
C:/Efinity/2026.1/bin/efx_run.bat ti60f225_cam_hdmi.xml --flow pnr --output_dir outflow_style_final --work_dir work_style_final
C:/Efinity/2026.1/bin/efx_run.bat ti60f225_cam_hdmi.xml --flow pgm --output_dir outflow_style_final --work_dir work_style_final
# 在上述仿真和构建结果都存在后，更新交付副本和 SHA256 清单。
python tools/package_style_demo.py
```

部署文件：`reports/style_demo/release/ti60f225_oob.bit`、`soc_video_app.elf`；`build_project.xml` 保存精确工程输入，`manifest.json` 包含部署文件、模型、构建时源码字节、资源/时序、完整帧和并发仿真的 SHA256 与指标。原工作区已有修改的 SHA256 也独立核对保持不变。训练/验证记录、比较图和关键 Efinity/仿真原始报告位于 `docs/style_demo_results`。

上板使用新 `.bit`，待 DDR 校准后按既有 IDE/JTAG 方式下载 `soc_video_app.elf`。应用开机等待现有任务/系数 CDC 空闲，加载权重，等待提交计数，运行 32×24 自测并校验完整输出；成功后开放视频流。CPU 重新下载时不假定硬件系数计数为 0。无需向板上 Python/PyTorch 移植教师。

CPU 自测通过后，UART 应输出 `STYLE INT8 RGB self-test PASS; MONET VGA`。OSD `CAP` 是接收并存储的帧率，`NN` 是完成推理的帧率，`DISP` 是刷新率，`DROP` 是累计队列/抓帧丢弃，`MS` 是最近完成网络的周期换算。需在真实相机输入、HDMI 与 CPU 同时工作时测量 NN FPS、丢帧、端到端延迟、DDR 效率及画质。当前未宣称实板满足 15/30fps、全帧不丢、双风格或 720p 网络推理。
