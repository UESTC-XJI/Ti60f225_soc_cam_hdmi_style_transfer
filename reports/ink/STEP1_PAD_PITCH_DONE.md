# Step 1 完成：PAD_PITCH 写入路径改造（已验证）

> 日期：2026-10-21
> 目标：让 `PAD_PITCH=1`（4 KiB 行对齐）可用 —— 补上相机抓帧的写入路径
> 结论：**改造完成，单元测试证明行间距正确从 2560 变为 4096**

---

## 一、问题定位（上一轮遗留）

**`PAD_PITCH=1` 会改变 DDR 布局**：

| 角色 | 布局 |
|---|---|
| `style_network` **读** | `input_pitch` = 4096（对齐后） |
| `style_frame_store` **写**（相机抓帧） | `cap_offset` 每 512 B 连续递增 = 2560/行（紧凑） |

**两者不一致 → 读到错位数据（输出 `00xxxxxx`）。**

---

## 二、实现（4 个文件）

### 1. `style_frame_store.sv` —— 行感知 stride

```verilog
module style_frame_store # (parameter FRAME_PIXELS=307200,
                            parameter FRAME_WIDTH=640,
                            parameter PAD_PITCH=0)(

localparam integer ROW_BLOCKS = (FRAME_WIDTH*4 + 511) / 512;   // 5 for 640
localparam integer RAW_PITCH  = FRAME_WIDTH*4;                  // 2560
localparam integer PAD_STRIDE = PAD_PITCH ? ((RAW_PITCH+4095) & ~4095) : RAW_PITCH;

reg [15:0] blk_in_row;
wire row_last_block = (blk_in_row == ROW_BLOCKS-1);
wire [31:0] PAD_STEP = (PAD_PITCH && row_last_block)
                     ? (PAD_STRIDE - (ROW_BLOCKS-1)*512) : 32'd512;

// 每块递增时维护 blk_in_row
cap_offset <= cap_offset + PAD_STEP;
blk_in_row <= row_last_block ? 0 : blk_in_row + 1;
```

**`PAD_STEP` 在两处生效**：
- 每行前 4 块：+512（正常）
- 行末第 5 块：+1536（从 2560 跳到 4096）

### 2-4. 参数透传链

| 文件 | 改动 |
|---|---|
| `style_video_system.sv` | 新增 `BURST_MAX`、`PAD_PITCH` 参数，传给 `store` 与 `accelerator` |
| `style_accel.sv` | 新增两参数，传给 `network` |
| `style_network.sv` | （上一轮已有）`BURST_MAX` / `PAD_PITCH` |

---

## 三、决定性单元测试（`work/ivtest/fs_pad_tb.sv`）

**方法**：向 `style_frame_store` 送入 1280 包（= 2 行 = 10 块），记录每次 AW 的地址。

### PAD_PITCH=0（紧凑，2560/行）

| 块 | 地址 |
|---|---|
| 0 | `0x05000000` |
| 1 | `0x05000200` |
| 2 | `0x05000400` |
| 3 | `0x05000600` |
| 4 | `0x05000800` |
| **5（第 2 行首）** | **`0x05000a00`** ← 连续，+512 |
| 6 | `0x05000c00` |
| 7 | `0x05000e00` |
| 8 | `0x05001000` |

### ⭐ PAD_PITCH=1（4 KiB 对齐，4096/行）

| 块 | 地址 |
|---|---|
| 0 | `0x05000000` |
| 1 | `0x05000200` |
| 2 | `0x05000400` |
| 3 | `0x05000600` |
| 4 | `0x05000800` |
| **5（第 2 行首）** | **`0x05001000`** ← **跳到 4 KiB 边界**，+1536 |
| 6 | `0x05001200` |
| 7 | `0x05001400` |
| 8 | `0x05001600` |

**对比**：
- PAD=0：第 2 行从 `0xa00` 开始（2560 = 0xa00）
- **PAD=1：第 2 行从 `0x1000` 开始（4096）**

**→ 行间距正确从 2560 变为 4096，改造成功。**

---

## 四、周期收益（上一轮已验证）

用 4096 布局输入跑全系统（640×48）：

| 配置 | 总周期 | 输出 word[0] |
|---|---|---|
| 基线（BM=32, PAD=0） | 1,178,504 | `00937455...` |
| BM=240, PAD=0 | 927,206 | `00937455...` |
| **BM=240, PAD=1** | **874,374** | **`00937455...`** ✅ |

**累计 −25.8%，输出逐位相同。**

---

## 五、⚠️ 一个重要的验证局限（诚实说明）

**全系统 tb 绕过了 `frame_store`**：
- tb：`input.hex` → `mem` 直接写入 → network 读
- 真板：相机 → `frame_store` → DDR → network 读

**所以 `frame_store` 的改造在全系统 tb 里不体现**（tb 用对齐版 input.hex 模拟了它的效果）。

**我为此单独做了上面的单元测试**，直接验证 `frame_store` 的写地址序列 —— 这是本次新增的验证。

**但仍有未验证项**：真实相机流经 `frame_store` 写入后再被 network 读取的端到端正确性，**需要上板**。

---

## 六、当前配置（安全）

| 参数 | 值 | 状态 |
|---|---|---|
| `BURST_MAX` | **240** | ✅ 启用（−21.3%） |
| `PAD_PITCH` | **0** | ⚠️ **默认关闭** |
| `STYLE_UOF` | **1'b0** | ✅ 启用 |

**为什么 PAD_PITCH 仍关闭**：
- 代码已完整（read + write 两侧）
- 但没有端到端板上验证
- 打开需要 `PAD_PITCH=1` 且**确认相机流正确**

**启用方式**：`style_video_system.sv` 第 12 行 `PAD_PITCH=0` → `1`

---

## 七、Git 状态

| 项 | 值 |
|---|---|
| 提交 | `d6ccd6c`（baseline） |
| 标签 | `perf-baseline-20261021` |
| 本轮改动 | **未提交**（4 个文件） |

**建议提交信息**：
```
feat(style): complete PAD_PITCH write path for 4 KiB row alignment

style_frame_store now strides each captured row up to a 4 KiB boundary
when PAD_PITCH=1, matching style_network's aligned input_pitch.  Verified
with a unit test that the second row starts at 0x...+0x1000 instead of
0x...+0x0a00.

Default stays PAD_PITCH=0 because the end-to-end camera -> store -> network
path has not been validated on hardware.
```

---

## 八、诚实边界

| 项 | 状态 |
|---|---|
| `frame_store` 行 stride 逻辑 | ✅ **单元测试验证** |
| 参数透传链完整 | ✅ 编译通过 |
| 周期 −25.8%（含 PAD） | ✅ 全系统仿真（对齐输入） |
| 输出逐位相同 | ✅ 三配置对比 |
| **真实相机流端到端** | ❌ **未验证（需上板）** |
| **DDR 控制器 256-beat 兼容** | ❌ 未验证 |
| **显示欠载** | ❌ 未验证 |
