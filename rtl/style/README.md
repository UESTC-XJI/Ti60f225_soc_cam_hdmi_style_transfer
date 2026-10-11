# style/ —— 上板线第一刀：显示链里的风格迁移插入点

> 依据：`上板线整网顶层-第一刀-修改指示.md`（Doubao 侦察）。
> 本文记**实测核过的**结论 + 侦察文档里没写到的坑。行号是核过之后的。

## 1. 插点（源码实测，**旧记录的顺序是错的**）

```
CSI-2 RX(RAW) → frame_buffer#checker0(DDR 三缓冲) → cvo_axi
              → debayer_top_2to1 → rgb_datax2(48b,2像素/拍) ──【style_pipe】──> vid_cnt 选择块
              → dvi_encoder → TMDS → 屏
```

- `ti60f225_oob_top.v`（**行号是本次改动之后**的）：`frame_buffer` L641、
  `rgb_datax2` 定义 L865、debayer 例化 L882、`ae_frame_stats` L904、`pos_vs` L914、
  **`style_pipe` 例化 L922**、vid_cnt 选择块 L951/953、`dvi_encoder` L1188、`debug_edb_top` L1219。
- ⚠ **debayer 不在存储路径上**（RAW 直接进 DDR），风格迁移**只能**插在
  `rgb_datax2` 与 vid_cnt 选择块之间。旧记录的 "Debayer→风格→cvo_axi" 顺序写反了。
- `rgb_datax2` 只有**两个**消费者：
  - `ae_frame_stats`（L904）—— **必须留在原画上**。留错地方 AE 会去追风格，曝光跟着画面跑。
  - vid_cnt 选择块（L951/953）—— 这两行是唯一的改动点（`rgb_datax2` → `style_rgb`）。
- `rgb_datax2` = `{p1B,p1G,p1R, p0B,p0G,p0R}`，**R 是最低字节**（debayer 注释 `//b,g,r,b,g,r`）。不许换位。

## 2. 时钟 / CDC（`ti60f225_oob.sdc` 实测）

| 时钟 | 周期 | 频率 | 谁在用 |
|---|---|---|---|
| `vid_clk_dvi2` | 13.468 ns | **74.25 MHz** | debayer、AE、frame_buffer 读侧 |
| `hdmi_tx_slow_clk` | 6.734 ns | **148.5 MHz** | vid_cnt 选择块、dvi_encoder |

- 两条是**各自独立的 `create_clock`**（不是 generated），只差 2:1。
- 而 v7 的 vid_cnt 块**本来就直接采** `vid_clk_dvi2` 域的渲染信号 ⇒
  `style_pipe` 按**同域**处理（`clk` 接 `hdmi_tx_slow_clk`，与下游采样域一致），**不加 CDC FIFO**。
- **实测结论**：整工程 PnR 后 `outflow/ti60f225_oob.cdc.rpt` = **"No Synchronizer warnings to report"** ✓
  —— 这条边界工具**不报**，侦察文档里"若报再查"的担心可以划掉。

## 3. 工程文件清单的坑（**花了两轮才撞出来**）

- `ti60f225_oob.xml` 的 `<efx:design_file name=...>` 全是**工程目录内的相对路径**，一个 `..` 都没有。
- 试着写成 `../../hw/style/rtl/style_pipe.v`（把新文件放工程外的 `hw/style/`）⇒
  **`efx_map` 直接崩**（`EXCEPTION_ACCESS_VIOLATION`，连**干净报错都没有**，日志里只留一段栈回溯）。
- ⇒ **本模块的文件必须放在工程内**：`rtl/style/style_pipe.v`。
  若日后要把 RTL 收进 `deliverable/`，那是**拷出去**（单向），别在两边各留一份改。
- ⚠ **手改 XML 加的那一行，`-f map` 会保留、`-f compile` 会抹掉**
  （compile 跑完 pnr/pgm 后从内部库重写 XML；实测抹掉后下一次跑就报
  `instantiating unknown module 'style_pipe'`）。
  ⇒ **持久做法是在 Efinity IDE 里 Add Source 一次**；命令行临时用可以跑前补一行。
  症状识别：报"unknown module"而不是语法错 ⇒ 先 `grep style_pipe ti60f225_oob.xml` 看清单里还在不在。

## 4. VIO 怎么加（**已做完，第 2 步**）

`debug_top.v` 是 Efinity **自动生成**的（文件头 `Do not modify`），但仓里有
`tools/generate_debug.py` 可以脚本化重生成 —— **不用开 GUI**。实测配方：

```bash
# ① 改 debug.json：往 vio0 的 probes 里加条目
#    方向就靠 `init` 编：**有值 ⇒ VIO 驱动我们**（debug_top 的 output）
#                      **None ⇒ 我们送进 VIO 观察**（debug_top 的 input）
#    本次加的：style_sel(1,'0x0')  style_busy(1,None)  style_done(1,None)
# ② 重生成（**必须用 Efinity 自带的 python311**，系统 python 没有 pydantic）
PYTHONHOME="G:/Efinity/2026.1/python311" EFINITY_HOME="G:/Efinity/2026.1" \
  /g/Efinity/2026.1/python311/bin/python.exe tools/generate_debug.py
# ③ 生成的端口名 = vio0_ + 探针名
```

⚠ 三个坑：
- 系统 `python` 跑会 `ModuleNotFoundError: No module named 'pydantic'`；
  光换 `python311/bin/python.exe` 不够，还要 **`PYTHONHOME` 指到 `python311`**（否则 `No module named 'encodings'`）。
- `EFINITY_HOME` 默认写死 `C:/Efinity/2026.1`（本机无此路径）。
- `vio0_clk = vid_clk_dvi2`（74.25M）= style_pipe 的**上游**域，而 style_pipe 采在
  `hdmi_tx_slow_clk`。`style_sel` 是**准静态控制位**，跨这点没关系，但别当数据通路用。

## 4b. 接了 VIO 之后怎么判"逻辑真的进去没有"（**别用全局 FF/LUT 差**）

实测：**整设计层面的 FF/LUT 不可比** —— 换成重生成的 `debug_top.v` 后，同样"无 style_pipe"
从 17742FF/32260LUT 变成 17316FF/30117LUT（**debug 核自己就变了 ±2k LUT**）；
而且 VIO 的**输入探针接常量时会被折叠**，所以"把模块关掉"也不是干净对照。

**可靠的办法：查网表 fanout**（`outflow/ti60f225_oob.map.v`）：

```bash
grep -c 'I3(style_sel_vio)' outflow/ti60f225_oob.map.v     # = 16 ⇒ 交换逻辑在
```

`style_sel_vio` 喂着 **16 个 `LUTMASK=16'h503f` 的 LUT4** = 2 像素 × {R,B} 两字节 × 8 位
= 32 个 2:1 mux ✓。**要是被剪掉，`style_sel_vio` 会一个 fanout 都没有。**
（唯一稳的资源数是 **RAMs**：全程恒 **93**。）

## 4c. 开 Debugger 之前：profile 要挑 **`debug.json`**，不是 wizard 那份

**症状**：从工程打开 Debugger，core 列表全是 `w_mipi_rx_hs/vs/de/data`、
`inst_efx_csi2_rx/…/Rx_HS_D_0` 这类 **la0 MIPI 探针，没有 `vio0`**。

**根因**：`ti60f225_oob.xml:168`

```xml
<efx:debugger>
  <efx:param name="profile" value="debug_profile.wizard.json" value_type="e_string" />
</efx:debugger>
```

`debug_profile.wizard.json` 是 `tools/generate_debug.py` 第 39–46 行用 `DbgWizard`
**另生成**的**自动 USER2 MIPI 分析仪**（1 个 la0 / 27 探针 / uuid `c96bc4fc…`）——
和片上跑的根本不是同一次构建。

**芯片里实际装的是** `debug_edb_top`（手动 USER1），`outflow/ti60f225_oob.res.csv` 里查得到：

```
+debug_edb_top_inst:debug_edb_top
   +vio0:edb_vio_top_…   INT_WIDTH=76  OUT_WIDTH=111
   +la0:edb_la_top_…     NUM_PROBES=6
```

⇒ **`File → Open` 直接开 `debug.json`**，core 列表就出 `vio0` + `la0`。

**怎么一眼确认打开的是对的那份**（三重对撞）：

| 项 | `debug.json` | 网表（比特流） |
|---|---|---|
| vio0 uuid | `2fa1141e…46cf` | `UUID=128'b…` 解出来一样 ✓ |
| la0 uuid | `8b991dc2…bec8` | 一样 ✓ |
| **探针位宽和** | 有 init 17 个 = **111** / 无 init 16 个 = **76** | **OUT_WIDTH=111 / INT_WIDTH=76** ✓ |

> ⚠ **`ada548a4f00d49f099c6ab581191edfb` 不是匹配键，别追它。**
> 那是 `rtl_gen.py:598` 的 `self._module_uuid = uuid.uuid4().hex` ——
> `write_debug_top_verilog` **每跑一次就新生成**，只当生成 RTL 里 `DBG_MODULE_NAME`
> 的**名字后缀**（所以网表里 `vio0`/`la0`/`debug_hub` 全带它）。**它不在任何 config 里，也不该在。**
> 按它去找"uuid 过期"是白费一轮 —— 已经白费过。

## 4d. VIO 面板按钮全灰 = **没连目标**，不是 profile 错

```python
# gui.py:1041 初始
self._context = VioGUIContext({'connected': False}, ...)
self.ui.tableWidget.setEnabled(False)                     # 开局就灰

# gui.py:1100 —— 表格使能只跟这一个走
def on_debug_core_state_changed(self):
    self.ui.tableWidget.setEnabled(self._context.state['connected'])

# gui.py:1175 —— 全文件里唯一把 connected 置 True 的地方
def on_debug_core_post_connect(self, dbg_sesh: DebugSession): ...
```

⇒ **"打开 profile" ≠ "连上目标"**。两者是分开的两步。

**连法**（Debugger 主窗口 **Run** 分组，标题也叫 "Configuration"）：

1. `USB Target` 选板载下载器
2. **`cb_user_instr` 选 `USER1`** —— 三处必须一致：
   工程 peri `ti60f225_oob.peri.xml` = `JTAG_USER1`、`debug.json` 的 `jtag_user` = `USER1`、这里选 `USER1`
3. 点 **`pb_config_jtag`**（按钮文字 `Configure`，tooltip "Start Capture"）→ 表格解除灰

⚠ **FTDI 是独占的**：`efinity.exe` 开着（尤其 Programmer 面板刚烧完）时 Debugger 抢不到，
现象是连不上/一直不亮。**先关 IDE 再连。**

## 5. 三步状态

| 步 | 内容 | 状态 |
|---|---|---|
| 1 | 直通占位 | ✅ 完成。map/pnr/pgm 全 PASS；`tb_style_pipe.v` ALL-PASS |
| 2 | VIO 拨 `style_sel`（0=直通 1=R/B 交换） | ✅ **完成（已上真板复现）**。`debug.json` +3 探针 → 重生成 `debug_top.v` → 顶层接线 → 全流程 PASS，新 bitstream 已出；交换逻辑经网表 fanout 证实真的综合进去了（§4b）。**2026-10-10 真板实测：Debugger 开 `debug.json` 连 USER1，把 `style_sel` 拨到 1，屏上红蓝确实对调（肉眼）** ⇒ VIO→RTL→HDMI 整条链路活着 |
| 3 | 接真内核 | ⏸ 见下 —— 没写到的坑比侦察文档说的多 |

**当前接线**（顶层 `ti60f225_oob_top.v`）：

| 信号 | 接法 |
|---|---|
| `style_sel` | ← `vio0_style_sel`（VIO 的 output；`init='0x0'` ⇒ **没人拨就是直通**，安全） |
| `start` | ← `pos_vs`（v7 现成） |
| `busy` / `done` | → `vio0_style_busy` / `vio0_style_done`（VIO 的 input，观察） |

**资源（最终一版全流程）**：FF 17737 / LUT 31497 / **RAMs 93** / DSP 12。
**RAMs 恒 93** = v7 基线 = "可用 163 块"那条账的口径 ✓。
（FF/LUT 单看没意义，见 §4b —— debug 核一重生就挪 ±2k。）

**时序**：`vid_clk_dvi2` 实测 161.4MHz（需 74.25）、`hdmi_tx_slow_clk` 实测 **163.7MHz**（需 148.5）
⇒ 插进去的 16 个 LUT4 没压垮显示域 ✓。最差 slack 落在 `CLK_5M` / `i_mipi_rx_pclk`
这类**既有**域（~0.03ns，正数），和插入点无关。

**已修的自身 bug（第 1 步剪掉、第 2 步才会炸）**：一像素按 `2*CH_WIDTH`（16 位）切了，
实际是 **3 通道 = 24 位** —— B 字节被整个丢掉、G 当成了尾字节。Verilog 不报错（零扩展），
而 `style_sel` 是常量 0 ⇒ 整块被综合剪掉 ⇒ **PnR 全绿也照样带着出厂**。
现在有 `tb_style_pipe.v` 挡着（直通逐位 + R/B 交换逐字节 + 组合零延迟 + `done` 电平）。

### 第 3 步的坑（**接真内核之前先想清这两条**）

**(a) 延迟不再是 0，`vs/hs/de` 要配等量行延迟。**
第 1 步是组合直通（零延迟），这是刻意的：vid_cnt 块把数据与 `rgb_vs/hs/de` **同拍**消费。
行流水的 3×3 要攒够 2 行才出第 1 行 ⇒ 输出天生比输入晚 **≥2 行**。
⇒ 必须给 `rgb_vs/hs/de` 配**同样的行延迟**（行延迟用计数器就行，不需要存数据），否则画面整体错位。

**(b) 帧边界那 2 行没有输入。**
显示链是**纯流式**（存的是 RAW，debayer 之后没有帧缓冲）。
帧 N 的第 1 行要出结果，需要帧 N-1 的**最后两行**，而那时流里已经没有它们了。三种处理：
- 行缓冲**跨帧不复位** ⇒ 每帧顶部出现**上一帧的 2 行**（错内容，但只 2/480 行）；
- 每帧复位 ⇒ 顶部 2 行是流水线充填（黑/垃圾）；
- 加帧缓冲 ⇒ 与"省掉帧缓冲"的设计前提冲突。

演示上**前两种都可接受**（2 行，肉眼基本看不出），但要**知情**地选。

**(c) `done` 做成了"电平"而不是"一拍脉冲"（对指示文档 §2 的有意偏离）。**
本模块跑 148.5MHz，一拍 = 6.7ns；而 JTAG VIO 的采样是 **kHz 级**，
**一拍脉冲根本采不到**（现象＝"done 一直是 0"，会被误判成模块没跑完）。
现在：**帧末拉高、下一帧开始拉低**（整个场消隐期保持），VIO 和轮询都能用。

**(d) 这条 inline 通路不是最终架构。**
它是在**显示时序里**跑（74.25MHz、2 像素/拍，不能断流），只适合**单层 / 轻量**的演示，
用来证明"插入没破坏通路 + 替换生效"。
真正的整网是 PLAN.md 的**帧级**形态（DDR 里输入帧 → 加速器 → 结果帧 → 显示读结果帧），
那条路才有地方放 12 层和乒乓。**别把 inline 当终点**。
