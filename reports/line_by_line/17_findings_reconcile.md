# 12 条已确诊发现 · 对账到当前现实（`5dfaf5a` → `6114e76`）

> 日期：2026-10-27 14:00　｜　只读审计：未改任何源文件、未构建、未接触板子
> 审计方法：**每条都用 `git log/show` + 当前源码 + 今日板上报告三方核对**，不采信任务描述里的转述。
> 基线 `5dfaf5a` → HEAD `6114e76`（6 个提交）。逐条 commit 的文件范围见 §1.1。

---

## 一、结论先行

### 12 条对账表

| # | 发现（一句话） | 判定 | 证据（file:line / commit） | 一句话备注 |
|---|---|---|---|---|
| 1 | 输出层被隐式 ReLU（`qlo` 符号决定） | **🟡 部分** | `requant.v:114` 未变（`git log 5dfaf5a..HEAD -- requant.v` **空**）+ `063c79a`（只换权重）+ `STARRY_ONBOARD_TEST:57-81`（**已复发**） | **靠权重绕过，RTL 没修；starry 实测已复发** |
| 2 | 遥测整块失效 | **🟡 部分** | `style_video_system.sv:110` 挂回 profiler，但 `style_ddr_profiler.sv:1-19` 只实现 5/12；`style_network_rowpipe.sv:137-141` 五个 `stat_*` **仍接 32'd0**；`video_apb_ctrl.sv:25` DISP 仍 0；`camera_3a.c:121-128` hot **已修** | 5 个 DDR 槽复活，7 槽 + 5 个 stat + fps 仍 0 |
| 3 | 外层 AXI 桥对显示读无优先 | **✅ 已修** | `soc_video_ddr_integration.sv:203-204`（`.DYNAMIC_VIDEO_READ(1'b1)` + `.video_read_urgent` 连线）+ `:7` 新端口；`0352fc3` | 1 根线 + 1 个参数，已落地 |
| 4 | 上电 452 ms HDMI 无同步 | **❌ 仍开** | `ti60f225_oob_top.v:861` `assign vid_rst_n=dly_cnt[26]`（未变）；`hdmi_startup_colorbar` 只有 `include`（`:27`），**实例数 = 0** | 兜底模块仍在库里躺着 |
| 5 | blob 是 14,448 B，不是 22,512 B | **🟡 部分** | `rowpipe_weights.h:1` 已改「903 beats = 14448 bytes」✅；`style_driver.c:39` **仍写 1,407 beat**；`ARCHITECTURE_FULL.md:175/261/339` **仍写 22,512 B** | 代码头修了，固件注释与架构文档没修 |
| 6 | 「只修一侧只值 +6%」 | **🔄 判断已变** | `cce5529` 提交信息实测：MS **58→51→50 ms**、B **86%→15%→19%**、AR 6→3%、RGAP 23→12%、**算力 33.2 ms 占 66%**；`rowpipe_frame_driver.v:130` `#(.MAXB(64),.DEPTH(256))` | 写侧 posted-B 一项就 −12%，读侧仅再 −2%，**瓶颈已转为算力** |
| 7 | CI/CO/COUT=16 是 2× 超配 | **❌ 仍开** | `rowpipe_engine.v:138` 仍是 `#(.CI(16),.CIW(8),.PIX(16),.CO(16),.COUT(16))`；RAM 仍 244/256 | 一行参数就能省 ~10 块 RAM，但没做 |
| 8 | AE 顶 4989 是固件常量 | **❌ 仍开** | `camera_3a.c:37` `#define CAMERA_VTS_OVERRIDE 2500u`（2×2500−11=4989，未变） | 注释已说明是"照度实验"的故意选择 |
| 9 | R 在 bit[7:0]（文档写 [23:16]） | **❌ 仍开（仅文档）** | `ARCHITECTURE_FULL.md:114` 仍写「**R 在 bit[23:16]**」；没有任何提交碰过该文档 | 代码本来就自洽，只差勘误 |
| 10 | 显示「细节损失」是测量口径 | **🔄 判断成立且被加强** | `style_display.sv:103-107`（XOR 只对右半，`063c79a`）+ `COLOR_CHECKER_CALIB:45-60`（显示链清白、**采集卡把偏色放大 1.5×**） | 结论对，但当年的 σ 数字已全部过时 |
| 11 | G/R σ 异常 = 增益 + 硬截断 | **✅ 已修（间接）** | `camera_3a.c:24-26` 增益 520/290/520 → **400/256/414**（`ff14419`）+ L11 有符号化后实测 σ **R 60.4 / G 55.8 / B 43.5** ⇒ G/R **0.92**（原 1.95） | 机制被证实，但没人为它修；是被"色卡校准 + L11 修复"顺手带走的 |
| 12 | 死代码清单（8 个） | **🟡 部分** | 8 个实例数**仍全为 0**；其中 `osd_apb_regs`/`osd_text_double_buffer`/`osd_fixed_text` **连 include 都删了**；`style_ddr_profiler` **已复活出列** | 从"8 死"变成"8 死 + 1 复活 + 3 个连编译都省了" |

**计数：✅已修 2 条（#3 #11）｜🟡部分 4 条（#1 #2 #5 #12）｜❌仍开 4 条（#4 #7 #8 #9）｜🔄判断已变 2 条（#6 #10）。**

### 1.1 六个提交到底改了什么（逐 commit 文件清单，判断"改没改"的依据）

| commit | 文件 | 与 12 条的关系 |
|---|---|---|
| `063c79a` | `rowpipe_weights.h`(1362 行) / `style_axi_rows.sv` / `style_display.sv` / `camera_3a.c` / `video_apb_ctrl.sv` / xml | **#1 的唯一修复动作（换权重）**、#10 |
| `3510267` | `style_ddr_profiler.sv`(+96) / `style_video_system.sv`(+29) / `camera_3a.c` / `camera_ae.c` / `style_driver.c` / `video_apb_ctrl.sv` | #2、C7（hot 位段） |
| `0352fc3` | `rowpipe_ddr_banks.v`(+286) / `soc_video_ddr_integration.sv` / `style_axi_cdc.sv` / `style_video_system.sv` / top | **#3**、#6 写侧 |
| `cce5529` | 仅 `rowpipe_frame_driver.v`(+8) | **#6 读侧**（MAXB=64/DEPTH=256） |
| `ff14419` | 仅 `camera_3a.c`(+9) | #11 增益 |
| `6114e76` | 仅 `docs/STYLE_LINEUP.md` | 无关 |

**关键事实：`requant.v` / `rowpipe_layer.v` / `conv3x3_core.v` 在整个区间零改动**（`git log 5dfaf5a..HEAD -- <这三个文件>` 输出为空）。所以 #1 的根因代码一行没动，#7 的例化参数一行没动。

### 1.2 当前现实快照（今日板上/构建实测，对账的"分母"）

| 指标 | 当前值 | 出处 |
|---|---|---|
| 帧时 / 帧率 | **50 ms / 18 fps** | `cce5529` 提交信息、`REPLY_TO_MODEL:112` |
| AXI 错误 / DROP | **0 / 0**（UF 2、FAULT 4 均为启动瞬态，之后不增） | `cce5529` 提交信息 |
| 输出 σ（R/G/B） | **60.4 / 55.8 / 43.5**（redsky v5） | `STARRY_ONBOARD_TEST:44` |
| 输出 mean（R/G/B） | +9.2 / +4.5 / +10.7；范围 −127…+115 | 同上 |
| 平坦区占比 | **36.6% → 0%**（`#989898` 归零），亮度 124（原画 128） | `063c79a` 提交信息 |
| XLR / RAM / DSP | **59,708 / 60,800（98.20%）**、244/256、147/160 | `cce5529` 提交信息 |
| setup 最差 slack | **+0.292 ns**（tx_cal_clk_90edge，DDR PHY 域） | 同上 |
| 相机增益 | **400 / 256 / 414** | `camera_3a.c:24-26` |
| 权重（代码库） | redsky v5，XOR `0xcbc67865`，903 beat | `rowpipe_weights.h:1`、`063c79a` |

⚠️ **一个必须点出来的状态不一致**：板子**当前跑的是 starry g075 权重 + 运行时改过的 L11 参数**（`STARRY_ONBOARD_TEST:135`），而固件里编译进的是 **redsky v5**；L11 的 bias 修正（64324/60688/33738）**只存在于 DDR，掉电即失**（`REPLY_TO_MODEL:111-114`）。⇒ **"板上现在是对的"和"代码库里是对的"是两件事**，下一次上电/重烧就会回到 redsky v5 + 固件里的 bias。这一条比 12 条里的任何一条都更容易造成"昨天还好好的"式误判。


---

## 二、逐条详细说明

### #1 输出层隐式 ReLU —— 🟡 部分（**权重绕过，代码未修，已实证复发**）

**当时的事实**：`requant.v:114` `ar = (qlo_r<0) ? a : (a>0?a:0)`；ReLU 无独立使能位，只由 `ld_qlo` 的符号决定。

**现在的实际行为**（我按 RTL 的 blob 解析规则重新解了当前 `software/firmware/rowpipe_weights.h`，903 beats = 14,448 B）：

| 层 | shift | qlo(原始/有符号) | qhi | ReLU |
|---|---|---|---|---|
| L0/L1/L2/L3/L5/L7/L9/L10 | 36~38 | 0 / **0** | 255 | **开**（这些层本来就该 ReLU） |
| L4/L6/L8（残差） | 30~31 | 129 / **−127** | 127 | 关 |
| **L11（输出层）** | **37** | **129 / −127** | **127** | **关** ✅ |

⇒ 当前 redsky v5 的 L11 量化头 `0x001fe065` 让 `qlo_s<0`，**ReLU 被绕过**。板上效果（`reports/L11_QUANT_FIX_2026-10-26.md:37-44`、`063c79a` 提交信息）：平坦区 **36.6% → 0%**、`#989898` 占比 **0%**、σ 24.2→58.8~61.7、亮度 124（原画 128）。**症状确实消失了。**

**但这不等于修好了。** 三条证据：
1. `requant.v` 没改（上方 git log 为空）；判据仍然是"`qlo` 的符号"。
2. `063c79a` 只改了 `rowpipe_weights.h` 里的量化头 + 三通道 bias + XOR —— 是**数据**，不是逻辑。
3. **复发已被实地拍到**：`reports/STARRY_ONBOARD_TEST_2026-10-27.md:57-81` —— starry g075/g085 的 Q 头是 `0x003fc027`（`shift=39 / qlo=0 / qhi=255`），结果「输出全为正、范围 0…+51、σ 7.7」；板侧只能**在运行时直接改 DDR 里的 Q 头**（`mww 0x06F03860 0x001fe065`）救回来，σ 7.7→30.9。

**⇒ 直接回答 Lead 的问题：新导出的权重只要再给 `qlo=0`，问题 100% 会回来**，而且不会报错、只会"画面发灰发平"，下次还得靠人肉发现 + DDR 直写 Q 头。这不是猜测，starry 这次就是这么复发的。

**根治选项（都不大）**：
- (a) **RTL 加显式使能**：`rowpipe_engine.v:96-99` 的位域表里 `[105:104]` 之后到 `[127]` 全是空闲位，取一位做 `relu_en`，`requant` 用 `relu_en ? max(a,0) : a`。代价：一次重综合（~12 分钟），面积 ~+2 LUT/通道。
- (b) **导出侧硬校验**：blob 生成脚本断言"末层必须 `qlo<0`"，不满足就拒绝导出。零 RTL 代价，但依赖模型侧遵守。
- 建议 **a+b 都做**：a 保底，b 让错误在导出时就炸而不是在上板时。

### #2 遥测整块失效 —— 🟡 部分（5/12 + 5 个 stat + fps 仍缺）

`git show 3510267` 确实把 profiler 挂回来了，但**只实现了 5 个槽**，原因写在 `style_ddr_profiler.sv:1-19`：恢复 12 个占 **661 FF / 384 LUT / 2 RAM**，PnR 到 99.82% 因拥塞失败（峰值 2.54）。所以：

| 原始失效项 | 现在 | 证据 |
|---|---|---|
| `DDR100M T/AR/DAR/RGAP/B`（0x58..0x64 中的 5 个槽） | **✅ 活** | `style_video_system.sv:110-121`、`style_ddr_profiler.sv:23-30` |
| profiler 其余 7 槽（4/5/6/7/9/10/11 → 0x68/6c/70/74/7c/80/84） | **❌ 恒 0** | 同上，`index` 未实现分支 |
| `RPMS/CPMS/PF/PFC/OVLP`（0xa8/ac/b0/b4/b8） | **❌ 仍恒 0** | **地址解码是通的**（`style_accel.sv:89` 已接 `*_snapshot`），但源头 `style_network_rowpipe.sv:137-141` 五个 `stat_*` **仍接 `32'd0`** |
| `DISP`(fps) @0xf8100024 | **❌ 仍 0** | `video_apb_ctrl.sv:25` `legacy_data=(paddr==0)?CORE_ID:32'd0` —— legacy 区只有 0x00 有值 |
| `hot` @0x0e8 | **✅ 已修** | `video_apb_ctrl.sv:179` `st_hot<=ae_rx[73:53]`（原 `[73:52]`，即 INDEX C7）+ `camera_3a.c:121-128` 恢复高光保护并加防御 |

**值得记一笔**：`camera_3a.c:121-128` 的注释把 C7 的后果写得很清楚——位段错导致 `hot` 实际读到 `≈2×hot+1`，"5.3% 热就贴底"，所以当初干脆把 `hot` 写死 0。**先修位段再恢复功能，这个顺序做对了**。

### #3 外层 AXI 桥无显示优先 —— ✅ 已修

`soc_video_ddr_integration.sv:203-204`：
```verilog
axi_shared_ddr_2m #(.DYNAMIC_VIDEO_READ(1'b1)) bridge(
  .clk(clk), .rst_n(rst_n), .allow_access(allow_access), .video_read_urgent(video_read_urgent),
```
- 新端口 `:7` `input wire video_read_urgent`；top 侧 `ti60f225_oob_top.v` 把 `style_demo` 导出的 `style_read_urgent` 接进 `soc_video_inst`。
- `style_video_system.sv` 里在模块边界打了**一拍寄存器**（`display_read_urgent_q`）专门断开"display FIFO 比较器 → arready 锥"的组合路径；内层桥仍用原始电平 `display_read_urgent_raw`。
- 参数 `URGENT_OVERRIDES_FAIRNESS=0`、`RESERVE_URGENT_READ=0` **保持默认**，所以是"有界优先"（视频最多连赢 3 次，CPU 每 4 次必得 1 次），不会饿死 CPU。
- 面积：外层桥重新引入 `video_read_streak`（2 FF）+ 约 10~12 LUT，`bridge` 实测基线 365 XLR → 约 380（见 `16_area_budget_track1.md` §5）。

**这条是 12 条里修得最干净的一条。**

### #4 上电 452 ms 无 HDMI 同步 —— ❌ 仍开

- `ti60f225_oob_top.v:861` 仍是 `assign vid_rst_n = dly_cnt[26];`（148.5 MHz 下 2^26 拍 = **451.9 ms**，串在 capture/display/style 全链的复位里）。
- `hdmi_startup_colorbar.sv` 仍然只有 `include`（`:27`），**实例数 0**；`bar_hs/bar_vs/bar_de/bar_r/g/b`（`:956-957`）仍是悬空 wire。
- 影响仍在：上电后前 0.45 s 输入恒 0（黑屏/无同步），而 `dvi_encoder` 3 拍就出复位。
- 修法没变：把 include 里现成的 `hdmi_startup_colorbar` + 帧边界切换 FSM 实例化，或把 `dly_cnt[26]` 降到 `[22]`（~28 ms）。**属于"代码在库里躺着、只差接线"的状态**（与 INDEX 判断一致）。

### #5 blob 是 14,448 B，不是 22,512 B —— 🟡 部分

| 位置 | 现状 |
|---|---|
| `software/firmware/rowpipe_weights.h:1` | ✅ **已改**：`/* rowpipe cap8 DDR blob: 903 beats = 14448 bytes */` |
| `software/firmware/style_driver.c:39` | ❌ **仍写**「布局 = INTERFACE.md sec 8 的 **1,407 个 16B beat**」 |
| `reports/ARCHITECTURE_FULL.md:175` | ❌ 仍写「22,512 B（1,407 个 16 B beat，DDR 记录为 903 beat / 14,448 B）」——同一行自相矛盾 |
| `ARCHITECTURE_FULL.md:261` | ❌ 「权重 blob … 22,512 B」 |
| `ARCHITECTURE_FULL.md:339` | ❌ 「3612 words，22,512 B blob 的 14,448 B 部分」 |

我顺手复核了数字：当前 `rowpipe_weights.h` = **3612 words = 14,448 B = 903 beat** ✅ 与 `wbase_of` 偏移表（L11 854 + ci4×9 + 13 = 903）吻合。**代码侧已对，两处文档仍错。**

### #6 「只修一侧只值 +6%」 —— 🔄 判断已变（有实测数据）

当时的推理是"读写两侧同时是瓶颈，只修一侧只值 +6%"。现在的实测（`cce5529` 提交信息，100 MHz AXI 计数器每秒差分）**推翻了这个比例**：

| 档位 | MS（帧时） | AR | DAR | RGAP | **B（等写响应）** |
|---|---|---|---|---|---|
| 原版 | **58 ms** | — | — | — | 86%（历史值） |
| B：posted-B（写侧，`0352fc3`） | **51 ms**（−12%） | 6% | 3% | 23% | **15%** |
| C：+ MAXB=64/DEPTH=256（读侧，`cce5529`） | **50 ms**（再 −2%） | 3% | 3% | **12%** | 19% |

**修正后的结论**：
1. **写侧是主导项**（−7 ms / −12%），不是"只值 6%"。历史 `wburst` 的 +6% 是**另一次失败尝试**的数字，不能用来预测 posted-B。
2. **读侧确实只剩 −2%** —— 但原因是"读等待已被算力掩盖"，不是"读侧不值钱"：AR 反压 6%→3%、RGAP 23%→12% 都说明长 burst 生效了，只是没转化成帧时。
3. **瓶颈已经换人**：算力 **4.925 M 拍 @100 MHz = 33.2 ms**，占 50 ms 的 **66%**。继续抠总线最多再拿 ~5 ms。
4. 现状：**50 ms / 18 fps**，AXI 错 0、DROP 0（`REPLY_TO_MODEL_20s_experiment.md:112`）。
5. 顺带一条**新发现**：`REPLY_TO_MODEL_20s_experiment.md:95-100` 指出"每层 1.2~1.5 ms（160×120），13.2 ms 只够加 8~10 层，不是 18 层"，且"加层会先撞面积（RAM 12 块 / XLR ~1,200）"。⇒ **下一步优化方向应从"总线"转向"算力/层数预算"**。

### #7 CI/CO/COUT=16 是 2× 超配 —— ❌ 仍开

`rowpipe_engine.v:138` 一字未改：
```verilog
rowpipe_layer #(.CI(16), .CIW(8), .PIX(16), .CO(16), .COUT(16)) u_layer (
```
12 层描述符实测 `ci ≤ 8`、`cout ≤ 8`（`style_network_rowpipe.sv:79-92`）。改 `.CI(8)` + `.CO(8)` 的收益（`01_rowpipe_layer.md` 要点 2、`16_area_budget_track1.md` §四）：
- `TILED=(8<8)=0` ⇒ tile 全套逻辑（`S_RLD`/`wrap1280`/三个读口 mux/72 个 `tile` 2:1/`wci` 减法器）被剪掉；
- `lb` 163,840 → 81,920 bit（**省 8 个 10 kbit RAM 块**）；`id_rb` 43,264 → 21,632（省 2 块）；`rq_id_r1..5` 640→320 FF；输出 FIFO 槽 258→194 bit。
- **RAM 244/256 的当下，这是唯一"只改一行例化参数"就能拿回 10 块 RAM 的手段** —— 而 `REPLY_TO_MODEL` 已经指出"加层会先撞面积"，等于**这条现在是加层的前置条件**。
- 风险：需重跑全套 TB（当前 rowpipe 全链零仿真覆盖，见 INDEX §六-5）。**建议在加层之前做，而不是之后。**

### #8 AE 顶 4989 是固件常量 —— ❌ 仍开（但是故意的）

`camera_3a.c:37` `#define CAMERA_VTS_OVERRIDE 2500u`，`:58` 写入 → `2*2500−11 = 4989` 半行。注释（`:34-36`）说明这是 `illum_20261021` 的实验：拉长 VTS 让传感器允许更长曝光。
- **不是 bug，是刻意配置**；但"AE 上限 4989"这个结论仍然成立，且它会连带压低帧率上限。
- 若要提速：VTS 越小帧率越高但曝光越短。**建议在"50 ms/18 fps"已经确定之后重新决策**：当前瓶颈是算力不是曝光，可以考虑把 VTS 降回 1125 换帧率，或保持 2500 换取照度。

### #9 R 在 bit[7:0] —— ❌ 仍开（纯文档，代码本就正确）

`ARCHITECTURE_FULL.md:114` 仍是：
> 「像素格式 | XBGR 4 B/像素，**R 在 bit[23:16]**」

而实测链路（INDEX §七裁决 1、`09_ddr_byte_encoding.md`）：`debayer_top_2to1.v:150-151` 拼接 `{b[15:8],g[15:8],r[15:8],b[7:0],g[7:0],r[7:0]}` ⇒ **低字节 = R**；`style_vga_crop.sv:16` 的 `pair_sum[c*9+:9]={1'b0,i_rgb[c*8+:8]}+{1'b0,i_rgb[24+c*8+:8]}` 是**逐通道同字节位置配对**（c 与 24+c，不做通道重排）；`ti60f225_oob_top.v:836` `hdmi_tx_rdata = display_pixel[7:0]`。
- **这条的价值已经变成"防止后人踩坑"**：`REPLY_TO_MODEL_20s_experiment.md:84` 给模型侧的说明里已经正确写成「R 在低字节」，说明知识已传到下游；**只剩主架构文档还错着**。
- 判定：**代码无需改，文档需勘误**。与 #5 合并成"一次文档重写"最省事。

### #10 显示「细节损失」是测量口径 —— 🔄 结论成立、数字全过时

- 代码侧：`style_display.sv` 仍是严格 1:1 拷贝（失败即黑），`063c79a` 只把 XOR 改成"只对右半"，**没有引入任何插值/缩放**。
- 当年的论证（23.0 是单通道 R 的 σ、12.3 是截图 luminance 的 σ）**已被新证据加强**：`COLOR_CHECKER_CALIB_2026-10-27.md:45-60` 用同一条链路做了颜色侧的三层归属，结论是「显示链清白：`^0x80` 不改差分、`tone` 只 +0.5、`lift` 是公共增益，**采集卡把偏色放大了约 1.5 倍**」——**同一个"测量假象"根因（USB 采集棒）在颜色维度被独立证实**。
- 但具体数字全部过时：当年 DDR σ = R 23.0 / G 44.9 / B 26.1；现在 = **R 60.4 / G 55.8 / B 43.5**（redsky v5，`STARRY_ONBOARD_TEST:44`）。
- ⇒ 判定：**结论保留，报告里的 σ 数字必须换新**，否则会误导（"σ 只有 23"这个前提已经不成立）。

### #11 G/R σ 异常 = 增益 + 硬截断 —— ✅ 已修（间接，机制被证实）

- 机制侧证据（INDEX 的推理）：`rgb_gain_v1.v:91-92` 是 Q8.8 乘 + 饱和（`mul>>8`，超范围时置满量程），**增益越大越早削顶**。
- 增益已改：`camera_3a.c:24-26` **R 400 / G 256 / B 414**（`ff14419`，为 24 色卡白平衡而定，`COLOR_CHECKER_CALIB:36`）。
  削顶阈值 ∝ 1/gain ⇒ R 从 `≈126`(gain520) 推到 `≈164`(gain400)，G(gain256) 基本不削 ⇒ **R 的 σ 被压扁的原因消失**。
- 实测结果（`STARRY_ONBOARD_TEST:44` redsky v5 三通道）：**σ R 60.4 / G 55.8 / B 43.5** ⇒ **G/R = 0.92**（当年是 44.9/23.0 = **1.95**）。
- ⇒ **异常消失，且方向反过来了**（现在 R 最大）。这反过来证明 INDEX #11 的"增益饱和"归因是对的。
- 注意：**它不是为修 σ 而改的**（是为色度 B−R 改的），属于"顺手治好"。机制仍在——把增益再调高就会复发，见 §三。

### #12 死代码清单 —— 🟡 部分

| 模块 | 实例数（当前） | include | 结论 |
|---|---|---|---|
| `osd_apb_regs` | 0 | **已删** | 死，且不再编译 |
| `osd_text_double_buffer` | 0 | **已删** | 死，且不再编译 |
| `osd_fixed_text` | 0 | **已删** | 死，且不再编译 |
| `osd_font8x16` | **2** | 有 | 死（两个实例分别在 `osd_fixed_text.sv:32`、`osd_text_double_buffer.sv:42`，**父模块都不实例化** ⇒ 传递性死代码） |
| `hdmi_info_overlay` | 0 | 有 | 死（只编译） |
| `hdmi_frame_histogram` | 0 | 有 | 死（只编译） |
| `hdmi_startup_colorbar` | 0 | 有 | 死（**#4 的兜底就是它**） |
| `capture_frame_stats` | 0 | 有 | 死（只编译） |
| ~~`style_ddr_profiler`~~ | **1** | — | **✅ 已复活**（`style_video_system.sv:110`），从死名单出列 |

不综合分支确认：`style_accel.sv:3` `parameter bit USE_ROW_PIPE = 1'b1`；`:108` `generate if (USE_ROW_PIPE) begin: g_row` → `:109` `style_network_rowpipe`；`:118` else 分支才是 `style_network`；`:126 endgenerate`。
`style_video_system.sv:74` 的实例化**没有覆盖该参数** ⇒ **else 分支（`style_network`/`style_row_core`/`style_mac8x12`）仍未综合** ✅（与 INDEX 判断一致）。

---

## 三、已修但仍脆弱（靠配置/权重绕开，代码层面没根除）—— 这些将来还会复发

| 优先 | 项 | 绕开方式 | 复发条件 | 复发后会怎样 | 根治代价 |
|---|---|---|---|---|---|
| **P0** | **#1 L11 隐式 ReLU** | 把 L11 的 Q 头改 `qlo=129(−127)/qhi=127` | **任何新导出的权重给 `qlo=0`** | 输出被 ReLU ⇒ 全正、σ 掉到 1/4、屏幕一大片同色。**已经实测复发**（starry，`STARRY_ONBOARD_TEST:57-81`） | RTL 加 `relu_en`（描述符有空闲位）≈ 2 LUT/通道 + 一次重综合；或导出脚本硬断言 |
| **P1** | **#2 遥测** | 只实现 5/12 槽（661 FF 会顶爆 PnR） | 想加槽时 | 又一次 99.8% + 拥塞失败 | 必须先腾面积（做 #7 的 CI=8 换 10 块 RAM / ~1.3k XLR 后再加） |
| **P1** | **#11 增益削顶** | 把增益从 520/290/520 降到 400/256/414 | 有人为"更亮/更白"再调高增益 | R/B 重新削顶 → σ 再次被压扁、"G/R 异常"回来 | 硬件侧给 rgb_gain 加饱和计数（或软件侧统计 `==255` 占比）以便**当场发现** |
| **P2** | **#5 / #9 文档数字** | 只改了 `rowpipe_weights.h` 头 | 任何人再引用 ARCHITECTURE_FULL / style_driver.c | 面积/带宽/位序推断全部自证 | 一次性重写 `ARCHITECTURE_FULL.md`（30+ 处偏差） |
| **P2** | **#10 的 σ 数字** | 无 | 有人复用 INDEX/旧报告的 σ | 误判"输出值域本来就窄" | 在新报告里标注旧数字作废 |

> 注：**"靠权重绕过"这一类是最危险的**——`reports/` 目录在 `.gitignore` 里（见 `063c79a` 提交信息），意味着**这些绕开参数只存在于权重 blob 里，代码库里没有任何断言**。一次"用旧 .bin 烧板"就能把所有板侧修复覆盖回去（`STARRY_ONBOARD_TEST:13-20` 已实测发生过：增益、AE 高光、A1 遥测全被打回）。

---

## 四、仍开的问题（按对交付的影响排序）+ 下一步

| 序 | 项 | 为什么排这个位置 | 建议动作 | 代价 |
|---|---|---|---|---|
| 1 | **#7 CI/CO=16 超配** | 它是**加层的前置条件**：RAM 只剩 12 块、XLR 只剩 ~1,000，而下一阶段的计划（加深网络）会先撞面积。且它只改一行例化参数 | 改 `.CI(8),.CO(8)` → 重综合 → 跑 titile TB 回归 | 一行 + 12 分钟构建，**风险中**（需 TB 兜底，当前 rowpipe 零仿真覆盖） |
| 2 | **#1 的根治** | 已是"随时会复发"状态（starry 已复发一次）。每次换风格都可能重演，且**不会报错** | (a) `requant` 加 `relu_en`（描述符空闲位）；(b) blob 导出脚本断言末层 `qlo<0` | a: ~5 行 RTL + 重综合；b: ~10 行脚本 |
| 3 | **#2 的剩余 7 槽 + 5 个 stat** | 现在做会再撞面积；**必须在 #7 之后** | 先做 #7 腾出面积，再把 profiler 补回 12 槽（661 FF） | 依赖 #7 |
| 4 | **#4 上电 452 ms** | 影响每次上电/重配 bit 的观感（黑屏 0.45 s），不影响交付指标 | 实例化现成的 `hdmi_startup_colorbar`（代码在库里），或 `dly_cnt[26]→[22]` | ~10 行，**低风险** |
| 5 | **#8 VTS 2500** | 是刻意配置，不是缺陷；但影响帧率上限 | 在"帧时 50 ms 由算力决定"确认后，重新评估 VTS（1125 换帧率 / 2500 换照度） | 一个常量 |
| 6 | **#9 + #5 文档** | 不影响功能，但会持续误导后来者（包括模型侧） | 与 `ARCHITECTURE_FULL.md` 的 30+ 处偏差一次性重写 | 纯文档 |

### 顺带核的三件事

**(1) 8 个死模块现在还是死的吗？** —— **是，8 个实例数全为 0**。细化：
- 3 个（`osd_apb_regs`/`osd_text_double_buffer`/`osd_fixed_text`）**连 `include` 都已删除** ⇒ 现在连编译时间都不占；
- 4 个（`hdmi_info_overlay`/`hdmi_frame_histogram`/`hdmi_startup_colorbar`/`capture_frame_stats`）**仍在 include 但零实例** ⇒ 只吃编译时间；
- `osd_font8x16` 有 2 个实例，但父模块都是死模块 ⇒ **传递性死代码**；
- **`style_ddr_profiler` 已复活**（1 实例），应从死名单移除。

**(2) `style_network`/`style_row_core`/`style_mac8x12` 还在 `USE_ROW_PIPE` 的 else 分支里吗？** —— **还在，且确实不参与综合**：`style_accel.sv:3` 默认 `1'b1`、`:108/:118` 的 generate 二选一、`style_video_system.sv:74` 未覆盖参数。⇒ 三个模块仍是"只为回退保留"的死重量。

**(3) APB 空洞地址清单（现在仍恒 0 的）**：

| 窗口 | 地址 | 现象 | 原因 |
|---|---|---|---|
| style | **`0xa8/ac/b0/b4/b8`** | **地址解码正常、值恒 0** | `style_accel.sv:89` 已接 `*_snapshot`，但 `style_network_rowpipe.sv:137-141` 五个 `stat_*` 硬接 `32'd0`（`style_driver.c:77-78` 已注明） |
| style(profiler) | **`0x68/0x6c/0x70/0x74/0x7c/0x80/0x84`**（7 槽） | 恒 0 | `style_ddr_profiler.sv` 只实现 0/1/2/3/8 |
| style | `0x20/0x24`、`0x2c`(读)、`0x85..0xa7` | 恒 0 | 无映射（`style_accel.sv:82-90` 只解 00/04/08/0c/10/14/18/1c/28/30/34 + a8..b8） |
| video legacy | **`0xf8100004..0xf8100030`（含 `0x24` = DISP/fps）** | 恒 0 | `video_apb_ctrl.sv:25` `legacy_data=(paddr==0)?CORE_ID:32'd0` |
| ~~style `0x54`/`0x58..0x64`~~ | — | **✅ 已活** | profiler 的 freeze/clear + 5 个槽 |

### 附加：INDEX §五「定时炸弹」的现状（顺带核到一条已拆）

| # | 状态 | 证据 |
|---|---|---|
| **C7**（`st_hot<=ae_rx[73:52]` 位段错） | **✅ 已拆** | `video_apb_ctrl.sv:179` 改成 `ae_rx[73:53]`；`camera_3a.c:121-128` 恢复高光保护并加 `v.hot>v.samples` 防御 |
| C1/C2（`hout*wout` 非 2^fmt 倍数 / 描述符不符 ⇒ 永久 busy） | ❌ 仍无看门狗 | `rowpipe_engine.v:418`、`rowpipe_frame_driver.v` 未变 |
| C3（`2*cfg_win==D` 时 tile 静默错） | ❌ 仍临界 | win=640、D=1280，靠"ci≤8 ⇒ tile 不触发"幸存；**做 #7（CI=8）会顺手把它彻底消除** |
| C4（`cout>8` 时高半区错） | ❌ 仍开 | `rowpipe_engine.v:338-348` vs `conv3x3_core.v:105` |
| C5/C6/C8 | ❌ 未变 | — |

> **C3 与 #7 是同一次改动**：把 `.CI(8)` 一改，`TILED` 变 0，C3 这颗雷同时被拆。这让 #7 的性价比更高（省 10 块 RAM + 拆一颗雷 + 为加层腾空间）。

---

## 六、复发检测清单（发版前跑，5 分钟，纯 grep/读寄存器）

把 §三 的"脆弱项"变成可机器检查的断言。**每条都在本次审计中用到了，直接可复用**：

| # | 检查 | 命令 / 方法 | 若不合格说明什么 |
|---|---|---|---|
| 1 | **末层 Q 头必须有符号** | 解 blob 最后一层量化头（beat 854+36+12=902，word[3608]）：`shift=w&0x3F, qlo=(w>>6)&0xFF`，断言 **`qlo ≥ 128`**（即有符号负） | 新权重又给了 `qlo=0` ⇒ **#1 复发**，屏幕上会出现一大片同色（不必等上板，导出时就能拦） |
| 2 | **blob 大小** | `grep -c '0x' rowpipe_weights.h` ÷ 4 ⇒ 应 **903 beat / 14,448 B** | 出现 1,407/22,512 说明用了旧导出 |
| 3 | **遥测槽** | 板侧读 `0x58..0x64` 5 个 + `0x84` 是否非零 | 全 0 ⇒ profiler 又没挂（`style_video_system.sv:110` 被删/参数被改） |
| 4 | **外层桥优先** | `grep -n "DYNAMIC_VIDEO_READ(1'b1)" rtl/soc_integration/soc_video_ddr_integration.sv` | 无命中 ⇒ #3 回退（显示欠载会回来） |
| 5 | **rowpipe 例化参数** | `grep -n "rowpipe_layer #" rtl/accel_rowpipe/rowpipe_engine.v` | 若已改成 `.CI(8)` ⇒ #7 已做（需重跑 TB 回归）；仍是 16 ⇒ #7 仍开 |
| 6 | **增益削顶** | 读源帧一行统计三通道 `==255` 占比（`0x05000000`）；>2% 说明 R/B 又在削顶 | ⇒ #11 的机制复发（σ 会被压扁） |

> 附加一条**流程**检查（比代码更重要）：`STARRY_ONBOARD_TEST:13-20` 记录的"烧旧 .bin 会把板侧修复全打回"仍在——**发版一律走 `cp 权重.h + build_firmware.sh`，不要烧 `artifacts/*.bin`**。

---

## 七、诚实边界


| 项 | 状态 |
|---|---|
| 每条判定都有 `file:line` 或 commit | ✅ 全部给出 |
| 是否逐个 `git show` 核过"改了没" | ✅ 6 个提交的文件清单逐一核对；`requant.v`/`style_accel.sv` 等关键文件用 `git log 5dfaf5a..HEAD --` 确认零改动 |
| 板上数据来源 | ◐ 全部引自今日/昨日的既有报告（`L11_QUANT_FIX`、`STARRY_ONBOARD_TEST`、`COLOR_CHECKER_CALIB`、`REPLY_TO_MODEL_20s_experiment`、`cce5529` 提交信息），**本次未接触硬件** |
| #11 的 σ 数字 | ◐ 用的是 redsky v5 的实测（σ 60.4/55.8/43.5）；未逐场景重测 |
| #6 的"−12%/−2%" | ✅ 来自 `cce5529` 的提交信息（作者上板实测）；我未复算 |
| #2 的面积数字（661 FF/384 LUT/2 RAM） | ✅ 来自 `style_ddr_profiler.sv:1-19` 文件头，我未复测 |
| 构建/综合 | ❌ 一次未跑（只读审计） |
