# 改动 A1/A2 只读复核：`style_ddr_profiler` 挂回 + `st_hot` 位段修正

> 复核对象
> - **A1**：`rtl/style/style_video_system.sv:79-106` 挂回 `style_ddr_profiler`，并把 `prdata` mux 扩到 `0x54` / `0x58..0x84`
> - **A2**：`rtl/soc_integration/video_apb_ctrl.sv:179` `st_hot<=ae_rx[73:52]` → `[73:53]`
>
> 约束遵守：**未修改任何源文件**、未跑综合/构建、**未读写 `_b.bat` / `outflow/` / OpenOCD**。
> 全部结论来自只读 `read` / `grep` / `Select-String`。凡"推测"均已显式标注。

---

## 结论摘要（先行）

| # | 复核项 | 判定 | 关键依据 |
|---|---|---|---|
| 1 | 22 个端口名逐个对齐 | ✅ **完全一致，24/24 无错接**；`c_rlast`/`c_wlast` 接**正确那一侧** | `style_ddr_profiler.sv:4-10` 的 24 端口与 `style_video_system.sv:95-101` 双向核对；模块**根本没有** `v_rlast`/`v_wlast` 端口，且 `read_active`/`write_response` 内部只与 `c_*` 相关（`:23-26`） |
| 2 | `network_idle(nn_ready)` | ⚠️ **可接受，口径略宽**（"加速器空闲"而非"网络空闲"） | `style_accel.sv:36 auto_ready=!pending&&coeff_idle`；`nn_ready` 同时是 `auto_start` 的握手 ready（`:75`），语义自洽 |
| 3 | APB 冲突（0x54 / 0x58..0x84） | ✅ **无写/读占用，不触发 PSLVERR，不产生等待态** | `style_accel.sv:43`（pready）、`:45-46`（pslverr 三个条件）、`:66-74`（写 case）、`:82-91`（读 case）逐条排除 |
| 4 | `profile_index` 位宽/下溢 | ✅ 窗口内 4 位够（最大 11）；⚠️ **下溢会发生**且低位地址 `0x00-0x07`/`0x18-0x47` 截断后落在 0..11 → `profile_value` 可能非零，**但被 mux 条件兜住，功能无害**（潜在陷阱） | 8 位无符号回绕 + 4 位截断的位运算推演，见正文 |
| 5 | `st_hot` 位段 | ✅ **修正正确**，`[73:53]` 恰好是 `ae_hot` 的 21 位，与 `[52:32]`/`[105:74]` 不重叠，位宽匹配 | `video_apb_ctrl.sv:164`（打包）+ `:179`（解包）+ `:56`（`reg [20:0] st_hot`） |
| 6 | 固件访问路径 | ✅ **无截断、不会误判成 VIDEO 区** | `top:629`（`paddr[15:8]==0x02`）、`top:637`（传 `[7:0]`）、`top:685`（VIDEO 侧 `psel&&!style_select`） |
| **A** | **额外发现（建议先看）** | 🔴 **`style_video_system.sv:84-86` 的新注释里 12 个计数器的编号与位序完全反向**，而固件的标签顺序是**对的** → 照注释读日志会把每个数都读反 | `style_ddr_profiler.sv:13-17` 的拼接顺序 + `style_driver.c:75,78-85` 的标签 |
| **B** | **额外发现（构建风险）** | 🟠 A1 新增 **384 个 flop + 12 个 32 位累加器**；文档记当前 XLR 利用率 **97.2%（59,132/60,800，仅余 1,668）** → **可能顶爆 P&R 或压垮时序** | `ARCHITECTURE_FULL.md:6`（文档值，未复核 outflow）；本次未读 `outflow/` |
| **C** | **额外发现（口径纠正）** | 🔴 **A1 并不能解决 ①「RPMS/CPMS/PF/PFC/OVLP 恒 0」**：那五个快照在 `style_accel` 的 `0xa8..0xb8`，与本 profiler 的 `0x58..0x84` 是**两套不同寄存器** | `style_driver.c:18-19,71-73,86-90`；`style_accel.sv:49-50,89-90,103`；`style_network_rowpipe.sv:163-167` |

**总判定：A2 可以直接合入（正确）。A1 的接线与地址分配是对的，但有 3 处需要处理——注释反向（必须改）、资源风险（必须评估）、以及它不解决 ① 这个预期偏差（必须澄清）。**

---

## 复核方法

| 我读了什么 | 用途 |
|---|---|
| `rtl/style/style_ddr_profiler.sv`（全文 33 行） | 端口名/位宽/events 位序——问题 1、4 的基准 |
| `rtl/style/style_video_system.sv`（全文 107 行，改动后） | 核对实例化、mux、freeze 逻辑 |
| `rtl/style/style_accel.sv`（:1-100 精读 + :100-128） | 问题 2、3：`pready`/`pslverr`/读写 case/`auto_ready` |
| `rtl/soc_integration/video_apb_ctrl.sv`（:158-202，改动后） | 问题 5 |
| `rtl/ti60f225_oob_top.v`（:626-639） | 问题 6 |
| `software/firmware/style_driver.c`（:11-19, :60-119） | 问题 6 + 额外发现 A、C |
| `rtl/accel_rowpipe/style_network_rowpipe.sv`（:140-171） | 额外发现 C 的旁证 |
| 未读 | `outflow/`（按要求回避）、`_b.bat`、OpenOCD 相关 |

---

## 问题 1：端口名逐个对齐

**模块声明**（`style_ddr_profiler.sv:4-10`）共 **24 个端口**：

| 序 | 声明 | 实例化（`style_video_system.sv:95-101`） | 一致? |
|---|---|---|---|
| 1 | `clk` | `.clk(clk)` | ✅ |
| 2 | `rst_n` | `.rst_n(rst_n)` | ✅ |
| 3 | `enable` | `.enable(stream_enable)` | ✅ |
| 4 | `freeze` | `.freeze(profile_freeze)` | ✅ |
| 5 | `clear` | `.clear(profile_write&&pwdata[1])` | ✅ |
| 6 | `network_idle` | `.network_idle(nn_ready)` | ✅ |
| 7 | `c_arvalid` | `.c_arvalid(c_arvalid)` | ✅ |
| 8 | `c_arready` | `.c_arready(c_arready)` | ✅ |
| 9 | `c_rvalid` | `.c_rvalid(c_rvalid)` | ✅ |
| 10 | `c_rready` | `.c_rready(c_rready)` | ✅ |
| 11 | `c_rlast` | `.c_rlast(c_rlast)` | ✅ |
| 12 | `c_awvalid` | `.c_awvalid(c_awvalid)` | ✅ |
| 13 | `c_awready` | `.c_awready(c_awready)` | ✅ |
| 14 | `c_wvalid` | `.c_wvalid(c_wvalid)` | ✅ |
| 15 | `c_wready` | `.c_wready(c_wready)` | ✅ |
| 16 | `c_wlast` | `.c_wlast(c_wlast)` | ✅ |
| 17 | `c_bvalid` | `.c_bvalid(c_bvalid)` | ✅ |
| 18 | `c_bready` | `.c_bready(c_bready)` | ✅ |
| 19 | `arvalid` | `.arvalid(v_arvalid)` | ✅ |
| 20 | `arready` | `.arready(v_arready)` | ✅ |
| 21 | `v_rvalid` | `.v_rvalid(v_rvalid)` | ✅ |
| 22 | `v_rready` | `.v_rready(v_rready)` | ✅ |
| 23 | `index[3:0]` | `.index(profile_index)` | ✅ 位宽 4=4 |
| 24 | `value[31:0]` | `.value(profile_value)` | ✅ 位宽 32=32 |

**结论：24 个端口名逐字一致，个数一致（无缺无多），位宽一致。没有接错。**

关于你特别问的 `c_rlast`/`c_wlast` 侧——**独立复核结论是「正确」，而且不是"沿用历史版本"的巧合，是被端口表强制的**：

1. 模块的端口表里**只有** `c_rlast`/`c_wlast`，**没有任何 `v_rlast`/`v_wlast` 端口**（`:6-8`）。所以"接错侧"这件事在语法上不可能发生——想接 `v_rlast` 会直接编译报错。
2. 更进一步确认语义：`c_rlast`/`c_wlast` 只被这两个内部状态使用（`:23-26`）：
   ```
   if(c_rvalid&&c_rready&&c_rlast) read_active<=0;
   if(c_wvalid&&c_wready&&c_wlast) write_response<=1;
   ```
   而 `read_active`/`write_response` 又**只**参与 `c_*` 相关的事件（`:14`、`:16`）。显示侧（`v_*`）在 `events` 里**只用** `arvalid/arready/v_rvalid/v_rready` 四个信号（`:16-17` 的 `v_rvalid&&!v_rready`、`:13` 的 `v_rvalid&&v_rready`、`:16` 的 `arvalid&&!arready`）——
   **这是合理的**：显示读是"只读 + 单笔消费"，profiler 只关心它的背压与消费，不需要它的"读事务结束"相位。
3. 边界确认：显示侧唯一的"读结束"信息本可以用 `v_rlast`，但模块作者选择不测；因此**不存在"本该接 `v_rlast` 而接了 `c_rlast`"的情况**——`c_rlast` 只能属于 CNN 通道。

> 结论：问题 1 通过，无需改动。历史版本 `4fdc3c8` 接法与此一致，但本次判定不依赖该版本，依据是端口表与 `events` 的内部自洽性。

---

## 问题 2：`network_idle(nn_ready)` 对不对？

**信号链**：`style_video_system.sv:38` 声明 `wire nn_ready` → `:63` `.auto_ready(nn_ready)`（`style_accel` 的输出）→ `:96` `.network_idle(nn_ready)`。

**`auto_ready` 的定义**（`style_accel.sv:36`）：
```
assign auto_ready = !pending && coeff_idle;      // pending = 有作业在跑
wire coeff_idle = issued==acknowledged;          // 系数 FIFO 已排空
```

**判定：合理 ✅**。`auto_ready` 高 ⟺ 没有任何作业在跑 **且** 系数通道已排空，这与"网络空闲/可接新作业"是同一件事——
它本身就是 `auto_start` 的握手 `ready`（`:75 if(auto_start&&auto_ready&&stream_enable)`），即"可以接受新作业"的官方信号。
把"可接受新作业"当作"空闲"来计数是标准做法，语义**自洽**。

**但有三个口径细节必须写进日志说明，否则会误读**：

1. **它还会因系数加载而为低**。`coeff_idle` 参与判断 → 上电/重配权重期间（`style_driver.c` 灌 24×… 系数）`auto_ready` 会长期为 0，
   会被计入"非空闲"。若你关心的是"网络算得慢"，这段会被错误地算进"忙"。**建议**：读日志时把权重加载期排除，或另接"`pending`=0"作为严格口径。
2. **`events[9]` 是电平、没有边沿限定**（`:13` 的 `network_idle` 直接进拼接，无 `&&!`）。所以 index 9 计的是**"空闲拍数"**，不是"空闲次数"。
   这与固件标签 `" IDLE "`（`style_driver.c:75`）以及"百分比 = delta[i]*100/delta[0]"的用法一致 ✅（拍数占比才有意义）。
3. **`enable(stream_enable)` 会整体闸门**（`style_video_system.sv:96` → profiler `:29 if(enable&&!freeze&&events[i])`）。
   `stream_enable` 为 0 时**所有 12 个计数器（包括 index 0 的"总拍数"）都停**。
   → 日志里 `DDR100M T` 的实际含义是"**stream_enable 为高的拍数**"，不是墙钟时间。固件用 `delta[0]` 作分母是自洽的 ✅，
   但**不要**把 label 里的 "100M" 理解成"1 秒 = 100,000,000"——除非 `stream_enable` 恒为 1。

---

## 问题 3：APB 冲突（`0x54` 与 `0x58..0x84` vs `style_accel`）

`style_video_system.sv:61-62` 把 APB 从口**整体**转给 `style_accel`，`pready`/`pslverr` **没有**参与 profiler 的 mux：
```
style_accel accelerator(... .prdata(accel_prdata),.pready(pready),.pslverr(pslverr) ...);
```
所以只要 `style_accel` 对 `0x54`/`0x58..0x84` 报错或拉低 pready，**profiler 的读就会带 PSLVERR 或挂起**。逐条排除：

### 3.1 `pready`
```
style_accel.sv:20  wire coef_write = psel&&penable&&pwrite&&paddr==8'h2c&&!pending;
style_accel.sv:43  assign pready = !(coef_write && !coeff_input_ready);
```
`paddr` 为 `0x54` 或 `0x58..0x84` 时 `coef_write=0` → **`pready≡1`，无等待态** ✅。

### 3.2 `pslverr`
```
style_accel.sv:44  wire is_config = paddr==8'h10||8'h14||8'h18||8'h28||8'h2c;
style_accel.sv:45-46 assign pslverr = psel&&penable&&pwrite&&(
                     (pending&&is_config) || (paddr==4&&pwdata[0]&&(!auto_ready||!config_ok))
                     || (paddr==8'h28&&pwdata[4:0]>23));
```
三个条件逐个代入：
| 条件 | 对 `0x54` | 对 `0x58..0x84` |
|---|---|---|
| `pending && is_config` | `is_config=0` → **假** | `is_config=0` → **假** |
| `paddr==4 && pwdata[0] && …` | `paddr≠4` → **假** | **假** |
| `paddr==0x28 && pwdata[4:0]>23` | `paddr≠0x28` → **假** | **假** |

→ **`pslverr≡0`** ✅（而且它还要求 `pwrite=1`，读访问无论如何都不会报错）。
**你的判断（0x54 安全）成立，我独立确认，包含读与写两种方向。**

### 3.3 `style_accel` 的读写 case 是否占用这两个地址
- 写（`:66-74`）：`8'h04 / 08 / 0c / 10 / 14 / 18 / 28` —— **不含 0x54，也不含 0x58..0x84** ✅ 写这些地址无副作用。
- 读（`:82-91`）：`0x00 04 08 0c 10 14 18 1c 28 30 34 a8 ac b0 b4 b8` —— **不含 0x54 / 0x58..0x84** ✅。
  最近的邻居是 `0x34`（`32'd148500000`）与 `0xa8`，中间 **`0x38..0xa7` 是空洞**，你们的窗口正好落在空洞里。
  → **`accel_prdata` 对这些地址本来就是 0**，所以 `prdata` mux 用 `profile_value` 覆盖它**不会丢任何东西** ✅。

### 3.4 顺手发现的两个"口径"问题（不阻塞合入，但应记录）
- **style 区没有任何地址错误上报**：`style_accel` 的 `pslverr` 只覆盖三个特例，**没有 `default: pslverr=1`**；读 case 也没有 default 赋值以外的检查。
  → 对 `0x38..0xa7` 这类空洞地址，**写会静默丢弃、读会静默返回 0**。
  这意味着：如果将来 profiler 的窗口写错一位（例如误以为基址是 `0x5c`），固件会**静默读到 0**，不会报错——
  **这正是 ①「恒 0」最容易被误判的形态**，值得在日志里加一条"读回 0x58 应为非 0，否则 profiler 未生效"的自检。
- **`profile_write` 没有参考 `pslverr`**（`style_video_system.sv:88`）。当前 `style_accel` 对 `0x54` 不报错，所以无实际影响；
  但如果将来 `style_accel` 增加了对未实现地址的 PSLVERR，会出现"软件看到写失败、但 freeze/clear 已生效"的不一致。建议加 `&&!pslverr` 保持与 `style_accel` 写 case 相同的门控风格（`:66`）。

### 3.5 `paddr` 8 位范围
`style_video_system` 的 `paddr` 是 `[7:0]`（`:8`），窗口 `0x58..0x84` 都在 8 位内 ✅，且 `0x84` 距 8 位上限还有 0x7B 余量。
在 STYLE 区（`0x200..0x2FF` 共 256 字节）内，`0x58..0x84` 占 12 个字（`0x58,0x5C,…,0x84`，间距 4，共 12 个）✅ 与固件的 `for(i=0;i<12;++i) regs[0x58/4+i]`（`style_driver.c:72`）**正好对应**。

---

## 问题 4：`profile_index` 位宽与下溢

```
style_video_system.sv:90  wire [3:0] profile_index=(paddr-8'h58)>>2;
style_ddr_profiler.sv:19  assign value = index<12 ? counters[index] : 32'b0;
```

### 4.1 窗口内（0x58..0x84）：4 位足够 ✅
`(paddr-0x58)` ∈ `0x00..0x2C`（0..44），`>>2` ∈ **0..11**，最大值 11 < 16 → **4 位 `[3:0]` 刚好够，无溢出**。
且 12 个索引与 12 个地址一一对应（`0x58+4i` ↔ `i`）✅。

### 4.2 下溢：**确实会发生，但被 mux 兜住**
Verilog 里 `paddr - 8'h58` 在 `max(8,8)=8` 位**无符号**下运算 → **按 256 回绕**，不会得到负数：
```
x    = (paddr - 8'h58) mod 256          // 8 位
idx4 = (x >> 2) & 4'hF                  // 4 位截断
```
代入 `paddr < 0x58`：`x = paddr + 168` ∈ `168..255` → `x>>2` ∈ `42..63` → 截断到 4 位后：
- `x>>2 ∈ {42,43}` → `idx4 ∈ {10,11}` ← 对应 `paddr ∈ 0x00..0x07`
- `x>>2 ∈ {48..59}` → `idx4 ∈ {0..11}` ← 对应 `paddr ∈ 0x18..0x47`

也就是说：**`0x00-0x07` 与 `0x18-0x47` 这些地址会让 `profile_index` 落在 0..11，从而让 `profile_value` 输出一个真实的计数器值**
（不是 0）。`0x18..0x47` 恰好覆盖 `style_accel` 的 `geometry(0x18)`、`last_cycles(0x1c)`、`coefficient_index(0x28)`、`0x30`、`0x34`（频率常数）等**重要寄存器地址**。

**但是否会造成实际错误？不会 ✅**，因为 `prdata` 选择了 `profile_value` 的条件是显式的窗口判断：
```
style_video_system.sv:106  (paddr>=8'h58&&paddr<=8'h84) ? profile_value : accel_prdata
```
`0x00-0x07` 与 `0x18-0x47` 都不满足 `>=0x58` → 走 `accel_prdata` ✅。**这个兜底在 mux 条件里，不在 index 里**。

**风险评级与建议**：
- 现状 **功能正确，无需改动即可合入**。
- 但这是一个**潜在陷阱**：如果将来有人放宽 mux（比如把窗口写成 `0x40..0x84`，或把 `profile_value` 挪去别处复用），
  就会在 `0x18..0x47` 上把 `geometry`/`last_cycles`/`coefficient_index` **静默读成 profiler 计数**，且 APB 不报错（3.4 节）。
- 两个低成本的加固（任选其一，**非必须**）：
  1. 把索引算成显式合法判据：`wire profile_hit=(paddr>=8'h58&&paddr<=8'h84);`，`profile_index` 只在 `profile_hit` 时取值；
  2. 或在 profiler 内把判据从 `index<12` 改成 `index[3:2]==2'b00 && index[1:0]!=2'b11`（等价于 `index<12` 但综合更明确）。

### 4.3 另一个位宽细节：`counters[index]` 的越界读表达式
`counters` 声明为 `reg [31:0] counters[0:11]`（`style_ddr_profiler.sv:12`），而 `index` 是 `[3:0]`（可取 0..15）。
`:19` 的 `index<12 ? counters[index] : 32'b0` 在**语义上**受三元保护（index≥12 时取 0），
但 `counters[index]` 这个**表达式本身对 12..15 是越界的**：
- 综合工具通常按三元条件建 mux，结果正确 ✅；
- 严格 lint / 形式工具会报 out-of-range，部分仿真器对越界读返回 x。
**建议**（可选）：改成 `value = counters[index & 3'hb]` 之类的显式掩码或用 `case`，让"越界必为 0"变成结构性保证而不是依赖三元求值顺序。

---

## 问题 5：`st_hot` 位段验算

**打包侧**（`video_apb_ctrl.sv:164`，改动前就在此）：
```
ae_payload <= {6'd0, cap_source_seq, ae_frame, ae_hot, ae_n, ae_y};
```
各位段宽度与位置（左到右 = 高到低）：

| 字段 | 宽度 | 声明依据 | 位段 |
|---|---|---|---|
| `6'd0` | 6 | 字面量 | `[143:138]` |
| `cap_source_seq` | 32 | `reg [31:0] cap_seq`（`:42`） | `[137:106]` |
| `ae_frame` | 32 | `reg [31:0] ae_frame`（`:133`） | `[105:74]` |
| **`ae_hot`** | **21** | `reg [20:0] ae_hot`（`:134`） | **`[73:53]`** ✅ |
| `ae_n` | 21 | `reg [20:0] ae_n`（`:134`） | `[52:32]` ✅ |
| `ae_y` | 32 | `reg [31:0] ae_y`（`:133`） | `[31:0]` ✅ |

宽度合计：`6+32+32+21+21+32 = 144` ✅ 与 `wire [143:0] ae_rx`（`:171`）和 `isp_cdc_mailbox #(.WIDTH(144))`（`:173`）一致。

**解包侧**（`video_apb_ctrl.sv:179`，改动后）：
```
st_y <= ae_rx[31:0];          // ae_y      32 位 → reg [31:0] st_y    ✅
st_n <= ae_rx[52:32];         // ae_n      21 位 → reg [20:0] st_n    ✅（未改动，本来就对）
st_hot <= ae_rx[73:53];       // ae_hot    21 位 → reg [20:0] st_hot  ✅（本次修正）
st_frame <= ae_rx[105:74];    // ae_frame  32 位 → reg [31:0] st_frame ✅
st_cfg <= ae_rx[137:106];     // cap_source_seq 32 位 → reg [31:0] st_cfg ✅
```

**逐项判定**：
1. `[73:53]` 恰好 21 位 = `ae_hot` 的完整宽度 ✅，与 `reg [20:0] st_hot`（`:56`）**位宽精确匹配，无截断**。
2. **不重叠**：`[73:53]` 与 `[52:32]`（`ae_n`）相邻不交；与 `[105:74]`（`ae_frame`）相邻不交 ✅。三段构成 `[105:53]` 的连续无缝划分。
3. **修正前后的差异（这就是原 bug 的准确描述）**：旧接法 `[73:52]` 是 **22 位**赋给 21 位寄存器 → 高位被截，
   实际得到 `{ae_hot[19:0], ae_n[20]}`：**丢了 `ae_hot[20]`、混入了 `ae_n[20]`**。
   `ae_n` 是采样数（满幅 1,228,800 < 2^21，故 `ae_n[20]` 当前恒 0）→ 修正前**数值上恰好等价**，属潜伏错误；
   一旦过曝像素数 ≥ 2^20 或采样数 ≥ 2^21 就会读错。**修正后彻底消除。**
4. **打包侧无需改**：`:164` 的拼接顺序与位移完全正确，**只改解包侧一处即完整修复** ✅。
5. 附带确认：`ae_payload` 是 `reg [143:0]`（`:138`），`ae_rx` 是 `wire [143:0]`（`:171`），两侧位宽一致，
   且 `isp_cdc_mailbox` 的 `WIDTH` 已被显式覆盖为 144（`:172` 的注释说明库默认 9 会静默截断）✅ —— **这一处没有遗漏**。

> **问题 5 结论：修正正确且完整，可直接合入。**

---

## 问题 6：固件访问路径（是否被截断 / 误判成 VIDEO 区）

**路径逐跳**：
```
style_driver.c:7-8   STYLE_BASE = 0xf8100200 ；regs = (volatile uint32_t*)STYLE_BASE
style_driver.c:71    regs[0x54/4] = 1;          → 0xf8100200 + 0x54 = 0xf8100254
style_driver.c:72    regs[0x58/4 + i], i=0..11  → 0xf8100258 .. 0xf8100284
top:629              style_select = (soc_apb_paddr[15:8] == 8'h02)
                     0xf8100254 → paddr=0x0254 → [15:8]=0x02 → style_select=1   ✅
                     0xf8100284 → paddr=0x0284 → [15:8]=0x02 → style_select=1   ✅
top:630-632          soc_apb_{prdata,pready,pslverr} 三选一 → 取 style_*          ✅
top:637              .paddr(soc_apb_paddr[7:0])  → 0x54 / 0x58..0x84             ✅ 低 8 位即窗口，无截断
style_video_system.sv:105-106  mux 命中 0x54 / 0x58..0x84                        ✅
```

**结论：完全正确 ✅**
1. **不会被误判成 VIDEO 区**：`style_select` 只看 `paddr[15:8]==0x02`，`0xf81002xx` 全部命中 style 区（top:629）。
   而 VIDEO 区要求 `[15:8]!=0x02`（top:685 `.psel(soc_apb_psel&&!style_select)`）→ 两区互斥 ✅。
2. **低 8 位不会被截断成别的东西**：`0x54`/`0x58..0x84` 都在 `[7:0]` 内；STYLE 区总宽正好 256 字节（`0x200..0x2FF`），
   窗口最大 `0x84` 距区边界还有 `0x7B`，**没有跨区风险** ✅。
3. **VIDEO 区内同低字节偏移不会撞车**：VIDEO 区 `0x54` 是"apply 配置命令"（`video_apb_ctrl.sv:77-81`）、
   `0x58/0x5C` 是 `cap_seq/disp_seq`（`:83-84`）、`0x80/0x84` 是 display 配置（`:89-90`）——
   但因为 `psel` 由 `!style_select` 门控，**两者永不同时被选中** ✅ 无运行时冲突。

**但必须记录一个"同名不同义"的坑（文档级，非 bug）**：

| 低字节 | STYLE 区（0xf81002xx） | VIDEO 区（0xf81000xx） |
|---|---|---|
| `0x54` | profiler `freeze`(bit0)/`clear`(bit1) | **apply 配置命令**（写 bit0=应用 gain、bit1=应用 display 配置） |
| `0x58` | profiler `counter[0]`（总拍数，只读） | `cap_seq`（只读） |
| `0x5C` | profiler `counter[1]` | `disp_seq` |
| `0x80/0x84` | profiler `counter[10]/[11]` | display `tone/lift/hist` 配置 |

→ 固件若**写错区基址**（例如把 `0xf8100254` 写成 `0xf8100054`），不会报错，而是**静默触发一次配置 apply**（`video_apb_ctrl` 的 `0x54` 写会校验并可能返回 PSLVERR，但读起来像"写失败"而不是"写错地址"）。
建议在日志首行加一句自检：读 `0xf8100200`（STYLE 区第一个可读寄存器应为 `captured`）与 `0xf8100000`（应返回 `CORE_ID=0x4f534431`）各一次，
确认基址没写错。**这是 ①「恒 0」的第二个可能解释**（第一个是 3.4 节的"空洞地址静默返回 0"）。

---

## 额外发现 A（🔴 建议优先处理）：新注释的 12 个编号与位序**完全反向**

你在 `style_video_system.sv:84-86` 写的口径是：
```
//   0=显示R消费 1=cpuR消费 2=空闲 3=等B 4=W等ready 5=AW等ready
//   6=显示R等消费 7=cpuR等消费 8=读气泡 9=AR等ready 10=cpuAR等ready 11=无条件(=总拍数)
```
但 Verilog 的拼接是**最后一个元素落在 bit 0**：
```
style_ddr_profiler.sv:13-17
wire [11:0] events = {v_rvalid&&v_rready,            // → events[11]
                      c_rvalid&&c_rready,            // → events[10]
                      network_idle,                  // → events[9]
                      write_response&&!c_bvalid,     // → events[8]
                      c_wvalid&&!c_wready,           // → events[7]
                      c_awvalid&&!c_awready,         // → events[6]
                      v_rvalid&&!v_rready,           // → events[5]
                      c_rvalid&&!c_rready,           // → events[4]
                      read_active&&c_rready&&!c_rvalid, // → events[3]
                      arvalid&&!arready,             // → events[2]
                      c_arvalid&&!c_arready,         // → events[1]
                      1'b1};                         // → events[0]
```
**真实编号（= 固件实际打印的编号，我已用固件标签独立验证）**：

| index | 真实含义（`events[i]`） | 固件标签（`style_driver.c:75,78-85`） | 你的注释 | 一致? |
|---|---|---|---|---|
| 0 | `1'b1` = **总拍数** | `"DDR100M T "`（delta[0]，且作分母） | 显示R消费 | ❌ **反** |
| 1 | `c_arvalid&&!c_arready` CNN AR 等 ready | `" AR "` | cpuR消费 | ❌ **反** |
| 2 | `arvalid&&!arready` **显示** AR 等 ready | `" DOWN "` | 空闲 | ❌ **反** |
| 3 | `read_active&&c_rready&&!c_rvalid` **CNN 读气泡** | `" RGAP "` | 等B | ❌ **反** |
| 4 | `c_rvalid&&!c_rready` CNN R 背压 | `" RBP "` | W等ready | ❌ **反** |
| 5 | `v_rvalid&&!v_rready` **显示** R 背压 | `" DBP "` | AW等ready | ❌ **反** |
| 6 | `c_awvalid&&!c_awready` | `" AW "` | 显示R等消费 | ❌ **反** |
| 7 | `c_wvalid&&!c_wready` | `" W "` | cpuR等消费 | ❌ **反** |
| 8 | `write_response&&!c_bvalid` 等 B | `" B "` | 读气泡 | ❌ **反** |
| 9 | `network_idle` | `" IDLE "` | AR等ready | ❌ **反** |
| 10 | `c_rvalid&&c_rready` CNN R 消费拍 | `" RB "`（delta[10]） | cpuAR等ready | ❌ **反** |
| 11 | `v_rvalid&&v_rready` **显示 R 消费拍** | `" DRB "`（delta[11]） | 无条件总拍数 | ❌ **反** |

**判定：固件是对的，注释是反的**（`labels[]`+`delta[0]` 作分母 + `delta[10]"RB"`/`delta[11]"DRB"` 三处全部指向"固件与位序一致"）。
你的注释恰好是**按写入顺序从 0 数**得到的，忽略了 Verilog 拼接的位序。
**影响**：不影响功能（RTL 与固件本来就一致），但**会误导读日志的人**——例如把 `DDR100M T` 当成"显示R消费"、把 `DRB` 当成"总拍数"，
这正是"性能数据看起来没意义"的典型来源。**建议把这 6 行注释按上表重写**（只改注释，不改逻辑）。

---

## 额外发现 B（🟠 构建风险）：新增逻辑量与当前利用率

A1 引入的**新增存储/逻辑规模**（静态估算）：
| 项 | 数量 | 说明 |
|---|---|---|
| 计数器 flop | **12 × 32 = 384** | `counters[0:11]`（`style_ddr_profiler.sv:12`） |
| 状态 flop | 2 | `read_active`、`write_response`（`:11`） |
| 32 位累加器 | **12** | `counters[i]<=counters[i]+1'b1`（`:29`） |
| 32 位 2:1 载入 mux | 12 | `if(clear)` / `if(enable&&!freeze&&events[i])` 的优先级选择 |
| 事件组合逻辑 | 12 项 + 比较器 | `events` 拼接（`:13-17`）+ `index<12` 比较（`:19`） |
| APB 小逻辑 | ~33 flop + 比较器 | `profile_freeze`（32）+ freeze 载入（`style_video_system.sv:87-94`）+ 三段地址比较（`:105-106`） |

按 K 级 LUT 估算，mux+adder 约 **600–800 LUT** 量级（具体取决于 Efinity 的进位链/加法器映射）。

**风险点**：`ARCHITECTURE_FULL.md:6` 记录当前资源为
**XLR 59,132 / 60,800（97.2%）、RAM 244/256、DSP 147/160**，即剩余 XLR 仅 **1,668**。
新增 600–800 LUT 属于**同一数量级**，**很可能把 XLR 推过 100% 或显著恶化布局/时序**（原本 slack 已接近 0）。
> 说明：① 该利用率数字来自文档，**本次未读 `outflow/`（按你的指示回避），未复核**；
> ② 上述 LUT 估算是**推测**，未实测。**建议你正好在跑的那次构建里核对 XLR 余量**。
>
> **如果构建失败或时序明显恶化，最小代价的规避方式**（不改功能）：
> 给 profiler 加一个 `parameter bit ENABLE_PROFILER=1'b1`，用 `generate` 包住，
> 关闭时把 `profile_value` 常量 0、`freeze` 寄存器也去掉——这样 profiling 可以随时"编译出去"而不必删代码。

**次要提醒**：12 个 32 位比较器/加法器共用 `enable`/`freeze`/`clear` 三个高扇出使能（`:29`），
fanout ≈ 12×32 = 384；在 100 MHz 下不是关键路径，但会给布线增负。

---

## 额外发现 C（🔴 口径纠正）：A1 **不解决** ①「五个快照恒 0」

你在背景里把 ①「RPMS/CPMS/PF/PFC/OVLP 五个性能快照恒 0」当作本次改动的动机之一。**这两件事不是同一套寄存器**：

| 寄存器 | 位置 | 固件读取 | 数据来源 |
|---|---|---|---|
| **12 个占用计数器**（本次 A1 挂回的） | STYLE `0x58..0x84` + `freeze@0x54` | `style_driver.c:71-73`（DDR 日志第一行） | `style_ddr_profiler`（本次新增实例） |
| **五个快照** RPMS/CPMS/PF/PFC/OVLP | STYLE **`0xa8..0xb8`** | `style_driver.c:18-19`（DDR 日志第二行） | `style_accel.sv:49-50` 的 `*_snapshot` 寄存器 |

证据：
- 固件：`style_driver.c:18-19` → `app_style_read_cycles=regs[0xa8/4]`、`0xac`、`0xb0`、`0xb4`、`0xb8`；打印在 `:86-90`。
- RTL：`style_accel.sv:89-90` 的 `8'ha8/8'hac/8'hb0/8'hb4/8'hb8` 返回五个 `*_snapshot`；`:103` 在 `if(core_done)` 时从 `stat_*` 载入。
- 数据源**是有驱动的**：`style_network_rowpipe.sv:163-167` `assign stat_read_cycles=cyc_rstall; …`，且计数器在 `:156-160` 逐拍累加。

**结论**：A1 合入后，DDR 日志**第一行**（`DDR100M T / AR / DOWN / … / DRB`）会从"全 0"变成真实数据 ✅；
但**第二行的 RPMS/CPMS/PF/PFC/OVLP 仍然是 0**，与 A1 无关。
① 的真实根因仍需单独定位，我在这次只读复核里能给出的**结构线索**（供下一轮用，**均为推测未定论**）：
1. `style_network_rowpipe.sv:153-154`：`else if (start) begin …全部清零…` —— 如果 `start` 不是 1 拍脉冲而是持续多拍，
   计数器会被反复清零 → `stat_*` 长期接近 0。
2. `style_accel.sv:103`：快照**只在 `if(core_done)` 那一拍载入**；若 `core_done` 与 `start` 同拍或先于 `start`，载入的可能是被清零后的值。
3. `style_network_rowpipe.sv:156` 的 `cyc_busy` 依赖 `drv_busy`；若 `drv_busy` 表现异常，`cyc_busy=0` → `stat_compute_cycles=0`。
> 建议把①拆成独立任务，从 `rowpipe_frame_driver` 的 `busy`/`start` 波形入手（这次不展开，避免超范围）。

---

## 额外发现 D（🟡 低风险）：`freeze`/`clear` 语义与固件行为的一致性

1. **`freeze` 生效晚 1 拍**：`profile_freeze` 是寄存器（`style_video_system.sv:91-94`），写 `0x54` 后**下一拍**才生效。
   固件在写之后执行了 `fence iorw,iorw` 再读 12 个字（`style_driver.c:71-73`），循环+函数调用开销远超 1 拍 → **实际安全** ✅。
   但如果将来把这个序列改成"写 freeze 后立刻读"（无 fence、无循环），就会有 1 拍的相干性窗口。
2. **`freeze` 只停计数、不清计数**（`style_ddr_profiler.sv:29 if(enable&&!freeze&&events[i])`）✅ 与注释/固件的"差分读取"用法一致。
3. **`clear` 从未被固件触发**：固件写 `0x54` 只写过 `1` 和 `0`（`style_driver.c:71,73`），**从不写 bit1** → `clear` 恒 0。
   因此计数器**只增不减**，靠固件的 `delta=snapshot-previous`（`:74`）做区间统计。
   - 好处：跨 32 位回绕时无符号减法仍然正确（`delta` 正确）✅。
   - 提醒：`enable=stream_enable` 长时间为 1 时，**每 2^32/100 MHz ≈ 42.9 s 回绕一次**；若某次采样间隔超过该窗口（例如调试器长时间暂停后），
     `delta[0]` 会变成很大的值，百分比会失真。固件注释（`:76-77`）已意识到"counter reset between snapshots"，属已知限制，**记录即可**。
4. **读 `0x54` 返回 `{31'b0, profile_freeze}`**（`:105`）→ 固件可以回读 freeze 状态做自检 ✅（当前固件没这么做，可选加）。
5. **`clear` 与 `freeze` 同拍写入时**：`clear` 优先（`:28 if(clear) counters[i]<=0; else if(...)`）✅ 语义明确（"清零并且冻结"）。

---

## 复核清单（我实际执行的只读操作，便于你复现）

| 操作 | 目标 | 得到的关键事实 |
|---|---|---|
| read 全文 | `rtl/style/style_ddr_profiler.sv`（33 行） | 24 个端口名、`events` 位序、`index<12` 判据 |
| read 全文 | `rtl/style/style_video_system.sv`（107 行） | 实例化 24 端口、mux、freeze 寄存器 |
| read :1-100 + :100-128 | `rtl/style/style_accel.sv` | `pready`(:43)、`pslverr`(:45-46)、写 case(:66-74)、读 case(:82-91)、`auto_ready`(:36) |
| read :158-202 | `rtl/soc_integration/video_apb_ctrl.sv` | `st_hot<=ae_rx[73:53]` 已生效（:179）、打包（:164） |
| read :626-639 | `rtl/ti60f225_oob_top.v` | `style_select`(:629)、`paddr[7:0]`(:637) |
| read :11-19, :60-119 | `software/firmware/style_driver.c` | 12 计数器读取、标签表、五个快照偏移 0xa8..0xb8 |
| read :140-171 | `rtl/accel_rowpipe/style_network_rowpipe.sv` | `stat_*` 有驱动、`start` 清零逻辑 |
| **未做** | 任何 write / `_b.bat` / `outflow/` / OpenOCD | 遵守约束 |

---

## 一句话总结

- **A2（`st_hot`）**：✅ 正确、完整，可直接合入。
- **A1（profiler）**：✅ 端口 24/24 无错接、`c_rlast`/`c_wlast` 侧正确、APB 地址无冲突无 PSLVERR、索引窗口 4 位够且下溢被 mux 兜住；
  **但要处理三件事**：① `style_video_system.sv:84-86` 注释的 12 个编号**整表反向**（只改注释）；② 新增 ~600-800 LUT 对 97.2% 的 XLR 余量有威胁（请用正在跑的构建核对）；
  ③ A1 **不解决** ①「五个快照恒 0」——那是 `style_accel` 的 `0xa8..0xb8`，需要单独一轮定位。