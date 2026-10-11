# 赛题一：从风格网络训练到Ti60F225 FPGA部署的完整方案

日期：2026-10-12。本文是设计方案，不是已实现的加速器或已训练的模型。依据赛题指南第4～7页、实际数据集审计和本工程P1/P2/P3优化后资源。用户现在要求讨论网络及加速器，因此本轮新增该方案；原资源优化的范围记录继续保留。

推荐路线：**非配对数据训练GPU教师 → 蒸馏小型BN学生 → INT8 QAT → 固定点逐层参考 → FPGA共享卷积引擎及融合行流水 → AXI共享DDR → 720p对比显示。** 先完成640×480持续30fps设计目标与单风格，再增加梵高/莫奈双权重切换。训练图、部署图和比赛验收分别留证，不把理论预算写成已达成性能。

## 1. 赛题要求与验收映射

来源：`../全国大学生嵌入式芯片与系统设计竞赛'2026FPGA赛道选题指南-易灵思.pdf`，第4～7页；第3页规定Ti60F225I3推荐平台，第4页VF-Ti60板的限制针对该另一款板。

| 赛题条款 | 本方案对应实现 | 验收证据 |
| --- | --- | --- |
| MIPI/RAW→RGB/Resize，最低640×480@30fps | 沿用SC431HAI、CSI、gain/Debayer；增加真实VGA裁剪/2×2平均缩放 | 连续完整帧计数、640×480像素序和实板采集30fps |
| 双缓冲，预处理帧存DDR且不丢帧 | 硬件管理原始帧/结果帧多bank及所有权 | 写入、推理、扫描读取不重叠；长时间序号无缺口 |
| 3×3或5×5卷积、激活、BN或IN硬件化 | 3×3普通/DW卷积、1×1 PW、ReLU、显式BN固定点仿射单元 | 各算子独立RTL测试及综合网表；不能仅把BN从结构中删除 |
| 加速器通过AXI从DDR读入、处理并写回 | 128位DMA及三主仲裁；融合块内中间量留片上 | AXI协议、数据/地址/响应、DDR拥塞回归 |
| HDMI最低720p60或1080p30 | 保留720p60时序，新增双源读取/对比画布 | 1650×750总时序、74.25MHz、画面同步与不撕裂 |
| RISC-V权重加载、调度及中断 | C驱动、硬件任务队列、完成/错误IRQ | RV32真实ELF和PLIC/ISR；当前userInterruptA接0，必须实际接通 |
| 原画/风格画对比 | 两个640×480画面左右并列，上下各120黑边 | 同一个frame_id的原图与结果图，OSD不参与网络输入 |
| VGA风格化稳定15fps以上 | 独立记录capture/infer/display FPS，最终设计以推理30fps为目标 | 计数已完成的新结果帧，不将HDMI60Hz重复帧算作推理60fps |
| 高阶：至少两种风格，不重配FPGA，切换<100ms且不丢帧 | 梵高、莫奈两套相同拓扑权重，任务边界锁存style_id | 旋钮/串口请求到首张新风格显示的实测延迟及无序号缺口 |
| 高阶：参数<500KB，质量/延迟比较 | 约8,251训练参数的候选学生；完整二进制<16KiB/风格目标 | 参数表、导出模型大小、教师/学生/定点对比，不只报卷积权重 |
| 高阶：720p30 | 后续独立优化目标 | 当前推荐网络720p计算量约为VGA的3倍，不宣称已满足 |

15fps是演示最低门槛，而采集最低30fps。如果要求长期处理每个采集帧且不丢帧，推理吞吐也必须达到30fps；有限缓冲不能永久补偿15fps推理对30fps输入的积压。若最终只能达到15～29fps，必须如实说明限速/抽帧策略，不能报告“全帧不丢”。

## 2. 当前数据集的实际情况

目录：`C:/OneDrive/comp/Ti60F225_DemoBoard_v4/soc_hdmi_test/archive`。

| 文件夹 | 数量 | 实际域 | 图像尺寸 |
| --- | ---: | --- | --- |
| trainA | 1,072 | 绘画，抽查与莫奈标签一致 | 全部256×256 |
| testA | 121 | 绘画，抽查与莫奈标签一致 | 全部256×256 |
| trainB | 6,287 | 自然照片 | 全部256×256 |
| testB | 751 | 自然照片 | 全部256×256 |

共8,231张，逐张解码无坏图。metadata将A域写成`A (Monet Painting)`，抽样包括睡莲桥、干草堆等莫奈主题；这更像monet2photo数据，**不能直接称为梵高数据集**。画家身份仍应追溯下载来源/作品列表，抽样和标签不是每幅作品的独立鉴定。

metadata.csv有8,231行且路径唯一，但242条指向不存在的文件，实际另有242张没有列出：例如画作测试文件被列到testB，照片文件被列到trainA。元数据统计的域/拆分与实际目录数量不一致。因此以文件夹枚举生成新的训练manifest，保留原CSV，不修改或“纠正”原图。

字节/完整RGB像素哈希没有发现train/test之间完全相同的图；有9组域内重复RGB图像，其中8组在trainB、1组在testB。近似图/同场景不同裁剪还未检测，需pHash+人工聚类后按组分配验证集，不能仅凭无完全重复认定没有泄漏。

可执行数据路线：

1. 当前A=画、B=照片，部署方向是**B→A**。不能按同名编号做配对L1训练。
2. 先用当前莫奈A域验证教师、学生、QAT及RTL链路。若目标是梵高，补充来源可追溯的梵高A域；照片B域可以复用，重新训练梵高教师/学生。
3. 两种风格使用两套权重，不需要把照片复制成所谓“梵高真值”。莫奈与梵高形成有区分的高阶双风格；同一套模型改变混合强度不算两种不同权重风格。
4. trainA/trainB内部抽约10%为validation，按作品/近似图/照片场景分组；testA/testB只在最终评估使用。保存seed、相对路径、SHA256、来源/许可及拆分版本。
5. 训练先使用256×256。现有源图没有VGA原生细节；放大到640×480不能产生真实高分辨率监督。可补充高分辨率自然照片及未来实际相机RGB用于分布校准，保留完整VGA测试序列。
6. RGB解码；训练随机裁剪、翻转、小幅亮度变化。验证固定预处理，不在test域调损失权重。近似图分组与去重只作用于新manifest，原目录保持原样。

审计工具：`tools/audit_style_dataset.py`；证据：`reports/style_transfer_planning/dataset_audit.json`、`dataset_contact_sheet.png`。这是图片/路径审计，不是风格训练结果。

## 3. 网络：GPU教师与FPGA学生分开设计

### 3.1 教师：CycleGAN用于产生学习目标

用常规6残差块CycleGAN教师作为第一基准，训练图含G(B→A)、F(A→B)、D_A、D_B。教师可以使用InstanceNorm、反射padding和Tanh；GPU训练后，FPGA只部署学生，不部署逆向生成器、判别器、VGG或训练优化器。

建议基线：Adam，lr=2e-4，betas=(0.5,0.999)，batch=1，LSGAN，cycle权重10、identity权重5，固定随机种子。先10～20 epoch检查方向、风格和内容，再根据validation收敛决定是否采用常规100 epoch固定学习率+100 epoch衰减。不要承诺一个未经测量的训练工期；也可使用来源清楚且确实对应该画家的预训练教师做起点。

身份损失训练的是正确方向的域样本；随机艺术图不是某一照片的对应GT。保存训练日志、checkpoint、训练/验证manifest哈希及固定照片比较图。先让教师有稳定风格和可辨认内容，才进行学生蒸馏。

### 3.2 推荐学生：24通道、4个残差块的轻量FNS式CNN

输入/输出均为640×480 RGB。网络全卷积，可先在256×256训练，再在640×480运行；尺寸改变需重新检查padding、BN统计及画质，而不是认为全卷积自动保证VGA质量。

DW表示逐通道3×3，PW表示1×1通道混合。各3×3均zero padding=1，stride2按PyTorch输出尺寸定义。上采样固定nearest（索引floor(x/2),floor(y/2)），不使用反卷积或硬件动态IN。

| 阶段 | 运算 | VGA输出尺寸 | 卷积权重数 | MAC/帧 |
| --- | --- | --- | ---: | ---: |
| E1 | Conv3×3，3→8，stride2，BN/ReLU | 320×240×8 | 216 | 16,588,800 |
| E2 | DW3×3，stride2，BN/ReLU；PW8→24，BN/ReLU | 160×120×24 | 264 | 5,068,800 |
| R1～R4 | 每块DW24→PW24→DW24→PW24＋残差 | 160×120×24 | 6,336合计 | 121,651,200合计 |
| D1 | nearest×2；DW24，BN/ReLU；PW24→8，BN/ReLU | 320×240×8 | 408 | 31,334,400 |
| D2/head | nearest×2；DW8，BN/ReLU；PW8→3，线性/clip | 640×480×3 | 96 | 29,491,200 |
| 合计 | 23个卷积原语 | VGA RGB | **7,320** | **204,134,400** |

残差块具体为DW→BN→ReLU→PW→BN→ReLU→DW→BN→ReLU→PW→BN→ADD→ReLU；最后PW在ADD前没有ReLU。卷积配BN的层bias=False，RGB head有3个bias。22个BN共464个通道，含gamma/beta后**训练参数8,251**；BN running mean/var及量化常数另计。FP32训练权重约33KB，部署INT8有效载荷约11KB，打包/补零/描述符后目标<16KiB/风格；最终以真实导出文件统计。

这种网络容量小，是待训练验证的候选结构，不是已证实能画出梵高笔触的模型。优先保留内容和明显风格；如果只有色偏，必须在软件阶段改结构/损失，不用“FPGA能跑”代替画质验收。

| 候选 | 参数 | VGA MAC/帧 | 理想MAC发射时间@148.5MHz | 用途 |
| --- | ---: | ---: | ---: | --- |
| C16/R2 | 2,771 | 101.53M | 11.25ms | 最小RTL/时序验证，画质风险更高 |
| **C24/R4** | **8,251** | **204.13M** | **18.10ms** | 推荐基线，先验证画质及30fps预算 |
| C32/R4 | 12,899 | 295.68M | 26.51ms | 画质候选，30fps余量小且导出/存储容量要重算 |
| C24/R4，720p | 同上 | 612.40M | 54.30ms | 当前引擎连理想计算也不到30fps，不作为现阶段承诺 |

时间按8输出通道×12归约项的96路MAC、所有层逐项计算，包含通道尾部浪费；**不包含DDR停顿、流水填空、归一化/残差调度和框架开销**。层表/算式由`tools/estimate_style_network.py`生成，可复核`network_layers.csv`及`network_budget.json`。

### 3.3 学生训练与视频稳定性

冻结训练好的B→A教师，学生拟合`T(photo)`。起始损失建议为`L_pixel + 0.1 L_perceptual + 0.01 L_style + 1e-5 L_TV`，均先规范各项量纲；pixel为输出与教师输出的L1，perceptual为固定VGG特征误差，style为与教师/目标风格Gram特征误差。系数是试验起点，不是已验证最优值。

先做纯蒸馏与内容保持；若风格弱再小权重加入D_A的对抗损失。FP32学生batch=8起步，GPU内存不足降低batch或梯度累积；BN运行统计用足够覆盖场景的数据校准，最后冻结。训练/校准不得用test图。可生成教师缓存加速重复实验，但记录教师checkpoint及输入变换，不能将不同随机裁剪缓存错配。

现有数据只有静态图，没有真实相邻视频监督。先对照片构造已知小平移/缩放，做带有效区域mask的`S(warp(x))≈warp(S(x))`一致性训练；以后加入实拍相邻帧和GPU光流mask的时序损失。光流只在训练中使用，部署图不增加光流算子。逐帧BN固定统计可减少动态IN引入的全局亮度跳变，但不能保证没有闪烁。

质量门槛：保留人物/文字/物体结构、风格可辨认，无严重棋盘格/边缘接缝，静态场景不过度闪烁。制作相同照片的原图、教师、FP32学生、INT8学生四列图；记录教师目标的PSNR/SSIM/LPIPS和风格Gram距离。非配对数据没有对应艺术真值，**不能把照片与艺术画直接计算PSNR当作风格质量评分**。赛题要求的质量/延迟比较可明确采用“教师参考输出”口径，并补充人工画质比较。

## 4. INT8与显式BN硬件约定

### 4.1 量化流程

1. 学生FP32达标，导出固定算子图，检查没有IN、动态shape、Tanh、反卷积或不支持的padding。
2. 权重对称INT8、逐输出通道scale；激活对称INT8、逐张量scale、zero_point=0。ReLU结果为0～127；RGB输入`q=u8-128`，对应`x=q/128`，这个约定也用于训练。
3. INT32累加。最大的普通归约为27项，PW为24项，DW为9项；仍显式扩位、signed乘法、禁止中间截断。残差相加先升9位，两支scale在QAT中约束一致，然后ReLU/饱和。
4. 做PTQ初试，再QAT微调（如lr=1e-5起点，收敛由验证决定）；冻结BN running统计，所有Conv/BN/requant/ADD/clip都要进入fake-quant图。全VGA和有代表性曝光/白平衡范围重新校准。
5. 编写NumPy整数参考，独立于RTL，每层输出与PyTorch fake-quant检查；生成小图和完整VGA向量。定点参考与RTL要求逐字节完全相同。

### 4.2 BN保留为可见仿射运算

训练/推理BN：`y = alpha * x + beta_eff`，其中`alpha=gamma/sqrt(var+eps)`、`beta_eff=beta-alpha*mean`。用离线运行统计计算常数，硬件对每个卷积输出实际执行乘法、加偏置、舍入和饱和，满足固定统计BN近似计算；不把“只剩Conv”当作BN模块证据。

若卷积整数累加为a，输入scale为s_x、该输出权重scale为s_w、输出激活scale为s_y，导出：

```
M = round(alpha*s_x*s_w/s_y * 2^r)
B = round(beta_eff/s_y * 2^r)
q_out = sat_int8(round_signed((int64(a)*M + B) / 2^r))
```

M为signed16，B为signed32，r为8位无符号；离线搜索合适r并验证范围/误差。乘加临时使用signed64；负gamma、负a和溢出必须覆盖。若某层无法在该格式达到精度，不静默截断，应调整scale/QAT或重新预算更宽格式。RGB head的bias和输出requant独立导出，不伪装成训练BN。

定点舍入统一为nearest、ties away from zero，正负均取绝对值加半LSB后再恢复符号；r=0特殊处理。Python、QAT近似和RTL必须明确舍入差异，最终以整数参考为准。输出先映射回RGB域再clip到0～255，禁止clip后回绕。

### 4.3 权重包/回放数据

导出`model.bin`、`model.json`、`weights.hex`、逐层`input/output.npy`及RTL向量。描述符含magic、版本、style_id、拓扑hash、shape、kernel/stride/pad、权重地址、BN M/B/r、activation scale、skip scale约束、RGB次序、舍入模式、CRC/SHA256。

为了96路MAC读带宽，权重按每次发射8×12矩阵排成96字节槽；DW每通道用9项，其余补0；通道/归约尾部补0。并行读需要768位宽，不能以“模型只有7KB”推断只需几个窄RAM。两种风格同拓扑分别有槽地址，活动style_id只在任务开始锁存。

BN按每次8输出通道排成64字节槽（每通道M16+B32+r8+flags8），使用512位参数读口。预计权重宽RAM约24块、BN宽RAM约16块，可在槽深度中放两种风格，实际以Efinity端口/位宽映射为准。这是资源估算，不能要求工具精确映射到某个未经验证块数。

## 5. FPGA计算结构与资源预算

计算复用已有148.5MHz vid_clk_dvi2；AXI/DMA在100MHz core_clk，HDMI仍74.25MHz。新增跨域command/result mailbox和数据双时钟FIFO，先验证reset/flush/ready，不直接将AXI握手跨域连线。不修改厂商加密CSI/DDR/Sapphire源。

```
APB任务/模式配置 → command CDC → CNN微序列控制
DDR128 DMA读 → 输入CDC FIFO → RGB解包/INT8
    → 行缓冲/窗口 → 96路共享MAC → 8路BN/requant → ReLU
    → 残差对齐/nearest上采样 → 输出CDC FIFO → DDR128 DMA写
                 ↘ 各融合块的行缓冲/skip环形缓冲 ↗
```

MAC映射：8输出通道×12乘加项；普通3×3收集kernel×Cin分块，PW按Cin分块，DW每输出通道9个tap并行。没有假定单DSP打包两个INT8乘法，每个乘法先按1个物理DSP预算。用valid/ready冻结所有窗口/累加/索引；BN延迟、ADD/残差延迟和输出frame_id一起传递。

融合边界：E2的DW/PW、每个R的DW/PW/DW/PW/ADD、D1和D2的nearest/DW/PW。DW输出直接进入PW，不落DDR；R的第二次DW使用第一PW的行缓冲，skip用输入环形缓冲按相同输出坐标对齐。微序列复用同一MAC阵列执行多个原语，需在仿真中证明每行及每个输出位置的缓冲活期，不允许一层整帧算完再假称“行融合”。

优先做完整宽度的行/条带流水，避免小tile重复halo开销。若后续用tile，每个双DW残差块在其尺度需要2像素halo，跨多个残差块halo进一步扩大；边界按训练zero padding，全帧无接缝对拍后才能优化。不能把256×256独立推理块直接拼成VGA输出。

| 资源 | 当前实际基线 | 新增预算上限 | 合计预算 |
| --- | ---: | ---: | ---: |
| XLR | 34,767 | 18,000 | 52,767 / 60,800 |
| RAM | 153 | 80 | 233 / 256 |
| DSP | 19 | 96 MAC＋16 BN | 131 / 160 |

RAM预算考虑768位权重读、512位BN读、行/skip缓冲、AXI跨域FIFO及VGA前处理，不能只按存储bit数除10Kb。BN的32×16乘法保守按拆成两个DSP、8通道共16块估算，实际需检查Ti60原语映射。额外逻辑覆盖DMA、仲裁、显示、VGA和控制；若综合超过预算，先减少并行度/缓存布局/融合深度再重新评估速度，不假定剩余26k XLR全部能用于MAC。

推荐结构的理想发射2,688,000拍≈18.10ms/帧，30fps只有33.33ms周期。30fps还要求数据/BN/融合调度有足够重叠；不能用14.256 GMAC/s峰值除MAC数宣称真实帧率。单引擎门槛是完整VGA事务在包括DMA后稳定≤30ms，保留约3ms调度余量。先在96DSP原型上map/PNR确认148.5MHz，若只能100MHz，理想计算已经26.88ms，需要重新选网络/并行度。

## 6. VGA输入、AXI/DDR和显示集成

### 6.1 真正640×480前处理

当前`rgb_area_resize_3to2`只实现1920×1080→1280×720，不支持任意640×480，不能只改width宏。推荐从1920×1080中心裁出1280×960（x=320..1599，y=60..1019），再2×2平均成640×480；保持4:3比例，牺牲部分视场。新模块`rgb_crop_box2_vga`只需前一行水平两像素和及垂直求和，三颜色通道最大1020，加2后右移2四舍五入。

沿用gain/Debayer和完整帧AE/AWB统计，VGA预处理位于其后，错误与帧完成计数纳入诊断。帧头、短行、缺行、reset、FIFO溢出不得发布有效VGA bank。保留旧720p预处理模式及回归，但正式VGA30路径需要新增完整仿真及实板检查。

已有RGB帧字约定是**0x00BBGGRR**，小端字节顺序R/G/B/0，不能误读成0x00RRGGBB。现有resize双像素的第一个像素在[63:32]，新DMA需把像素顺序定义到地址上并用颜色条验证。特征图用紧凑NHWC INT8，C8/C24不逐像素padding到16/32字节；行跨度在本网络中天然16字节对齐。

### 6.2 共享DDR不是已有可直接挂第三主设备的总线

`axi_shared_ddr_2m.sv`当前只有CPU+视频两个主设备、一笔未完成读和一笔未完成写。新增CNN DMA必须升级成CPU/视频/CNN三主仲裁，或增加经证明等效的层级仲裁；不直接将CNN信号并到视频端。视频主端还需区分capture写与display读任务。

保留128位总线、AXI完整本地ID/响应归属；DDR4位ID需重新规划owner/tag，不能沿用单owner bit假设。建议一个读/写burst outstanding起步，控制器为每笔事务保存完整源ID并在B/R恢复。优先保障显示FIFO低水位和采集FIFO高水位，CPU和CNN仍有有限等待上界，防止启动/I²C控制/权重加载饿死。

DMA使用INCR、16字节对齐、通常16/32 beat突发，遇4KiB边界截断。R/B响应错误、early/missing RLAST、WSTRB、背压稳定及reset后旧响应均要验证。任务完成必须等最后一笔B OKAY，并且跨域pipeline/FIFO都已排空，不能在发出WLAST时就发布结果帧。

### 6.3 新地址规划（提议，尚未实现）

保留现有CPU程序/BSS/栈、0x01000000 scratch及原0x04000000..0x04A8C600视频区。新区域都在板载256MiB DDR范围内：

| 区域 | 范围，右端为开区间 | 用途 |
| --- | --- | --- |
| 模型加载/描述符 | [0x02000000,0x02100000) | CPU/loader访问，不与程序及scratch重叠 |
| VGA原始帧池 | [0x05000000,0x05800000) | 6 slots，每slot0x00140000，有效载荷0x0012C000 |
| VGA结果帧池 | [0x05800000,0x06000000) | 同样6 slots，只有完成且B OKAY后可显示 |
| 特征工作区 | [0x06000000,0x06400000) | ping/pong各1MiB，有效最大614,400字节，另留guard |
| 拍照保留区 | [0x06400000,0x06600000) | 可选，复制匹配帧后独立保留；不包含手机传图实现 |

六slot为调度余量而非无限排队：每slot记录FREE/CAPTURE/READY/INFER/COMPLETE/DISPLAY状态、frame_id、cfg_seq、时间戳、style_id。捕获不写正在推理/显示的原图；结果不覆盖显示bank；比较视图始终锁住一对同frame_id的原图和结果。当前bank_switch没有CNN读锁，必须扩展或用新frame_bank_manager，不能直接复用其“最新三帧”切换。

### 6.4 DDR带宽核算

融合图共有8次DDR pass：E1、E2、4个R、D1、D2；不把每个DW/PW单独落DDR。VGA原始/结果32bit帧1,228,800字节；半分辨率C8特征614,400；四分辨率C24特征460,800。

| 流量 | 理想有效载荷带宽 |
| --- | ---: |
| CNN各融合pass读写9,523,200字节/帧 ×30fps | 285.696 MB/s |
| 捕获VGA写DDR ×30fps | 36.864 MB/s |
| 左右两个VGA画面读取 ×60Hz | 147.456 MB/s |
| 合计 | **470.016 MB/s** |

黑边在HDMI端生成，不读DDR。该数字不含AXI/DDR效率、仲裁、刷新、对齐和权重更新余量；不能用128bit×100MHz=1.6GB/s标称值替代测量。压测目标建议总持续有效带宽≥650MB/s且CNN有≥350MB/s可用，在该负载下显示/采集无下溢溢出。仿真应扫描可用带宽/随机长停顿，不只用每拍ready=1内存模型；最终必须实板测量。

若生成一整张720p对比图再写DDR，会多出合成读取/写入并继续每秒读取720p画布，不使用这个方案作为首版。直接两源扫描能降低DDR流量，但这是新显示读取逻辑，不是当前CVO自动具备的功能。

### 6.5 720p对比显示与风格切换

保留CVO/HDMI标准720p60时序；新增source reader在y=120..599时，x=0..639读原图、x=640..1279读风格图，其他行输出黑色。两端都是实际640×480，不冒充1280×720网络推理。全屏模式可做保比例nearest放大与左右黑边，后续再加更好的显示插值。

显示VS时只接纳完成的pair描述符；旧bank只有上次读事务与预取FIFO消费完才释放。旧结果可以重复扫描，但INFER_FPS不增加。RGB/DE/HS/VS及区域选择一起延迟，沿用文字OSD三拍；显示直方图需标明统计的是哪一视图。

CNN输入不含OSD/UI。现有tone/lift位于显示链路，不能不经比较就再次改学生输出颜色；建议风格区域旁路显示tone/lift，原图区保留或用统一经过校准的显示约定。相机AE/AWB仍依据原采集统计工作，风格输出不反馈给曝光。

两套权重预加载片上，CPU只切请求style_id。任务启动锁存该id，整帧各层使用同一风格；切换只影响下一任务。测量从消抖后命令接受到首张新风格结果显示，记录请求/应用frame_id，目标<100ms。模式改变只在显示帧边界应用，未就绪仍显示旧完整pair。若做不到无帧序号缺口，不宣称达成高阶切换要求。

QSE四档建议：0原画、1梵高、2莫奈、3当前风格对比；DEBUG按钮切换诊断OSD，SHUTTER冻结/保留匹配照片。旋钮输入需两级同步和10～20ms消抖，蓝牙仅用作命令/状态通道，不将BLE串口描述为实时视频推流。GPIO/UART引脚配置和扩展板电气以既有扩展方案为准，本方案没有实施它们。

## 7. RISC-V/APB驱动和中断

沿用VIDEO_BASE=0xF8100000、现有0x000..0x1A0映射；拟在同一16位APB窗口增加0x0200..0x02FF给加速器，由APB router选择，避免重生成SoC。当前video_apb_ctrl会拒绝这个范围，必须增加实际译码，更新CAPS/版本或提供独立ACCEL_VERSION。合法APB setup/access、wait/error规则仍要验证。

| offset，相对VIDEO_BASE | 寄存器提议 |
| --- | --- |
| 0x200 / 0x204 | ACCEL_ID / VERSION |
| 0x208 / 0x20C | CTRL START/ABORT/AUTO；STATUS busy/done/fault |
| 0x210 / 0x214 | IRQ_ENABLE / IRQ_STATUS，W1C |
| 0x218 / 0x21C | SRC_ADDR / DST_ADDR |
| 0x220 / 0x224 | WIDTH_HEIGHT / SRC_DST_STRIDE |
| 0x228 / 0x22C | MODEL_ADDR / MODEL_BYTES |
| 0x230 / 0x234 | STYLE_REQUEST / STYLE_ACTIVE及model_valid |
| 0x238 / 0x23C | REQUEST_FRAME_ID / DONE_FRAME_ID |
| 0x240 / 0x244 | PERF_CYCLES / DMA_STALL_CYCLES |
| 0x248 / 0x24C | ERROR_CODE / COMPLETED_COUNT |
| 0x250 / 0x254 | queue/bank诊断 / DROPPED_COUNT |

CTRL/任务字段用shadow寄存器，START时校验并原子锁存；busy期间写shadow不污染在途任务。模型仅可写非活动/非引用bank，CRC/拓扑不符不置valid；初始全部model_valid=0，不读未知参数RAM。

当前wrapper将userInterruptA接常0；计划实际接加速器完成/错误level IRQ，确认SoC内PLIC对应source编号后实现enable/priority/claim/complete。ISR先读取/保存状态并W1C外设，再PLIC complete；错误中止DMA后恢复时不能影响DDR校准/视频复位。轮询可用于第一步排障，正式交付必须验证中断路径，而非只声明寄存器有IRQ位。

驱动函数建议`style_model_load()`、`style_request()`、`style_submit_frame()`、`style_service()`、`style_irq_handler()`。CPU只加载参数、配置任务/队列和UI，不执行逐像素卷积，也不逐像素搬运视频。等待不得阻塞AE/AWB/I²C主循环，使用有界超时；自动队列仍由CPU配置策略、buffer池和模型版本。

权重可先作为小型const数组随ELF/JTAG加载，再用loader搬入参数RAM；后续才处理独立上电/Flash发布。当前工程不是权重加载机制已经完成的状态。保持CPU程序窗口和4KiB栈约束，const数组大小必须进入链接检查。

CPU和DMA不具备硬件cache一致性：先确认Sapphire实际write-through/write-back配置和BSP支持的clean/invalidate指令，再定义producer/consumer屏障。CPU写模型/描述符后必须让数据到DDR并fence；DMA写回后CPU需要invalidate相应区再读。不得在有dirty cache时仅invalidate而丢弃模型写入，也不能以volatile代替cache维护。正常帧数据由DMA/显示读取，CPU只读寄存器，不扫描完整图像。

## 8. 仿真、综合与实板的完整验证链

### A. 模型/整数正确性

- FP32教师、FP32学生、fake-quant、整数参考四种输出对同一输入留档。
- 逐算子随机向量及边界：signed INT8极值、不同kernel/stride、首尾padding、DW channel order、BN负gamma/负偏置/舍入、r=0、ADD scale/饱和、nearest偶奇坐标、RGB clip。
- 8×8/32×24小图全层逐字节对拍，随后256×256和640×480整网；不得仅比最终CRC而不定位第一处偏差。

### B. RTL单元与融合块

- 共用96MAC的CONV/DW/PW三模式、全部有效/ready组合、通道尾部与pipeline stall。
- 每个BN/ADD/nearest与独立整数oracle一致；模式切换排空，参数银行初值/载入/CRC验证。
- 融合E2/R/D1/D2与非融合整数图逐像素一致，行缓冲/skip寿命、整帧边缘、随机停顿和中途reset。
- 用颜色条/地址递增图验证0x00BBGGRR及现有双像素第一个位置，避免颜色/像素次序错误。

### C. DDR、调度、IRQ及显示

- DMA 16/32beat、4KiB截断、W/R/B backpressure、ID路由、BRESP/RRESP注错、reset残留、timeout/abort。
- CPU+capture+CNN+display并发；长期公平性和显示deadline；随机几百/几千拍DDR停顿、带宽上限扫描。
- VGA捕获30fps、CNN任务目标30fps、HDMI扫描60Hz的完整帧序号比对；slot不足必须增加错误/丢帧计数，不能悄悄覆盖。
- 同frame_id左右比较，晚任务保持旧pair，换风格只能整帧生效；所有在途DDR读完才释放bank。
- 真实RV32 ELF执行model_load/CRC失败/启动/IRQ claim-complete/W1C/timeout及AE/AWB并行服务，另外验证实际PLIC及IRQ RTL链路。
- 继承现有APB/3A、OSD像素、启动彩条、帧率诊断、resize/DMA/CVO和shared-DDR回归。

### D. Efinity及板卡

先单算子/融合块OOC map/PNR，再整网与本工程合并完整compile。检查DSP实际数量/位宽、宽ROM/行缓存的BRAM映射、同步读延迟、CDC、148.5/100/74.25MHz最终setup/hold，以及既有未匹配JTAG/接口警告。资源超标/时序失败必须回到网络和并行度预算，不能交付“理想帧率”。

离线整网建议仿真报告同时给无停顿周期数和拥塞分布下周期数；物理DDR/DSP/CSI/cache表现不由Icarus模型证明。当前无板卡连接，实板阶段待板卡可用后执行：先DDR/原画稳定→CPU加载模型→单帧比较→连续30fps→双风格/按钮→长时间与供电热稳定。

实板最少记录CAPTURE_FPS、INFER_FPS、DISPLAY_HZ、端到端latency、frame_id差、DROP/ERR、DDR stall、style switch latency。以完成新推理帧计数作为15fps/30fps证据；另测相机曝光+读出、队列、CNN、等待VS各自延迟。连续运行至少10分钟作为第一项稳定性门槛，保留UART日志及视频，不把软件仿真帧率当实测。

## 9. 分阶段执行与退出条件

| 阶段 | 交付物 | 可以进入下一阶段的条件 |
| --- | --- | --- |
| M0 数据/需求冻结 | 已有审计；新增可信manifest、梵高域来源、拆分和颜色约定 | 数据实际画家/路径明确，独立test不污染 |
| M1 教师效果 | 莫奈链路试验，梵高B→A教师、基准图片/日志 | 内容可辨认且目标风格明显；不止颜色滤镜 |
| M2 学生选型 | C16/24/32小范围对比、参数/MAC/质量表 | 选定网络在VGA有足够画质并可落资源/时间预算 |
| M3 QAT/整数规范 | model.bin/json、逐层golden、误差报告 | RTL目标图固定，无未知算子；模型导出大小和范围通过 |
| M4 算子/计算原型 | MAC/BN/ReLU/ADD/nearest、DDR单帧及OOC报告 | bit-exact，DSP/RAM实映射，目标时钟有裕量 |
| M5 融合与DMA | 行流水整网、三主仲裁、VGA bank/显示、APB/IRQ C驱动 | 全VGA拥塞下满足周期预算，无非法覆盖/协议错误 |
| M6 项目整合 | 完整回归、PNR/bit、配套ELF及manifest | 新旧功能全部通过，资源和最终时序通过；仍不等于实板验证 |
| M7 实板基础要求 | VGA采集30、风格推理>15并以30为目标、720p60对比和FPS | 长时间可观测稳定、真实frame_id/drop/latency记录 |
| M8 高阶双风格 | 两套参数预置、旋钮/串口动态切换、<100ms证据 | 不重配置、不丢帧；另行评估720p30网络/硬件方案 |

每阶段通过再扩大规模；不先做大加速器再发现小网络没有画质。模型、权重包、RTL、固件、约束、bit必须用hash绑定成同一发布版本。现阶段没有训练成果/加速器RTL/实板性能可用，因此不给未经测量的训练时长、硬件完成日期或画质/帧率保证。

## 10. 建议新增文件及本轮完成范围

后续实现目录（提议，尚未创建实现代码）：

```
ml/style_transfer/      datasets.py, teacher_train.py, student.py,
                       distill.py, qat.py, export.py, integer_reference.py
rtl/style_accel/        mac96.sv, window_buffer.sv, bn_requant.sv,
                       fused_block.sv, model_bank.sv, style_dma.sv,
                       style_scheduler.sv, style_apb_regs.sv
rtl/soc_integration/    axi_shared_ddr_3m.sv, frame_bank_manager.sv,
                       video_apb_router.sv, style_display_reader.sv
rtl/resize/            rgb_crop_box2_vga.sv
software/firmware/     style_accel.c, style_accel.h
tests/style_accel/     算子/融合/整网/DDR/IRQ/显示向量和测试
reports/style_transfer_release/  配套权重/bit/ELF与验证证据
```

本轮实际完成：赛题原文核对、8,231张图片/metadata审计、候选网络逐层参数/MAC/理想周期与DDR有效载荷估算，以及本完整方案。没有训练模型、安装PyTorch、实现/编译加速器、访问开发板或修改已通过的P1/P2/P3 RTL。

重跑本轮审计/预算：

```powershell
python tools/audit_style_dataset.py --dataset C:/OneDrive/comp/Ti60F225_DemoBoard_v4/soc_hdmi_test/archive --output reports/style_transfer_planning
python tools/estimate_style_network.py
```

2026-10-12重新检查训练环境：RTX5070约12GiB显存，驱动610.62；系统Python3.12.10和3.14.6均已有PyTorch2.11.0+cu128、torchvision0.26.0+cu128，支持sm_120。两者均实际通过CUDA矩阵计算、Conv/BN/ReLU反向传播与Adam更新、FP16 AMP训练步和torchvision CUDA NMS测试。建议后续训练显式使用`C:/Users/SteveGoodmann/AppData/Local/Programs/Python/Python312/python.exe`，无需为启动训练重装PyTorch/CUDA。

本机nvcc所属Toolkit为12.6，PyTorch自身CUDA runtime为12.8，二者不是同一个版本字段。Codex自带Python3.12.14仍没有torch，这是此前检测的环境；系统Python可用，不代表所有解释器都装有相同依赖。检测证据见`reports/style_transfer_planning/python_cuda_py312.json`、`python_cuda_py314.json`及`python_cuda_codex.json`。这些是小型训练步骤测试，不是风格网络完整训练或吞吐基准。
