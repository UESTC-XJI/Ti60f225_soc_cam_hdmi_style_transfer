# 串口切换单/双画面：方案与资源评估

> 日期：2026-10-23
> 目标：不依赖物理按键，通过 UART 命令切换「双面板 / 居中单面板」
> 关键约束：当前资源 **59,517 / 60,800（97.89%，余 1,283）**，增量必须很小

---

## 一、结论

| 项 | 答案 |
|---|---|
| **可行吗** | ✅ **可行** |
| **推荐方案** | **APB 寄存器 + 按键 XOR**（路径 A） |
| **RTL 增量** | **约 5–10 XLR**（1 FF + 1 位 XOR） |
| **固件增量** | 约 40 行 C（非阻塞 UART 轮询 + 命令解析） |
| **总风险** | 🟢 **低**（不动数据通路） |

---

## 二、技术路径选择

### 已确认的通路

```
UART ──> 固件 ──> APB 总线 ──> style_accel ──> ?
                                      ↑
                          （accelerator 直接挂 APB，
                           prdata 经 paddr mux 返回）
```

`style_video_system.sv:61` 里 `style_accel accelerator(... .psel(psel) ... .paddr(paddr) ...)` —— **accelerator 就是 APB 从设备**。

### 三条候选路径对比

| 路径 | 做法 | RTL 增量 | 评价 |
|---|---|---|---|
| **A（推荐）** | `style_accel` 加 1 个 APB 可写位，引出到 `style_video_system`，与按键 **XOR** | **5–10 XLR** | ✅ 最干净，单寄存器单线 |
| B | 走 `video_apb_ctrl` 的 `display_config`（128 位 CDC） | 改跨模块连线 | ⚠️ 那套配置在 `video_apb_ctrl` 里，`style_display` 在 `style_video_system` 里，不是同一条通路，改动大 |
| C | 复用 `stream_enable` 等已有位 | 0 | ❌ 语义混乱，会让两条功能互相干扰 |

**选 A。**

---

## 三、方案 A 详细设计

### 3.1 RTL：加 1 个 APB 可写寄存器

`style_accel.sv`：

```verilog
// 新增端口（1 位输出到 video_system）
output reg style_mode_sw,        // 1 = 强制单面板；0 = 跟随按键

// 新增 APB 寄存器（选一个未占用的地址）
8'hbc: style_mode_sw <= pwdata[0];        // 写：设置模式
8'hbc: prdata = {31'b0, style_mode_sw};   // 读：回读当前值

// 复位
style_mode_sw <= 1'b0;
```

**地址选择**：`0xbc` 当前未被占用（已用的是 `0x00/04/08/0c/10/14/18/1c/28/30/34/a8/ac/b0/b4/b8`）。

### 3.2 RTL：与按键组合

`style_video_system.sv`：

```verilog
wire single_panel_key;
style_key_toggle key_panel_toggle(.clk(clk),.rst_n(rst_n),.key_in(key_panel),.toggle(single_panel_key));

// 串口写 1 = 强制单面板；写 0 = 回到按键控制。
// XOR 让按键仍能翻转，但串口置 1 后按键也能切回，行为可预期。
wire single_panel = single_panel_key ^ style_mode_sw;
```

**⚠️ 重要**：这个 `style_mode_sw` 来自 `clk` 域（APB），`style_display` 内部已做了 `clk → pix_clk` 同步，`single_panel_clk` 也已同步。**不需要额外 CDC**。

### 3.3 资源占用估算

| 项 | 位宽 | XLR 估计 |
|---|---|---|
| `style_mode_sw` 寄存器 | **1 FF** | ~1 |
| APB 地址译码（`paddr==8'hbc`） | 8 位比较 | **~2** |
| `prdata` mux 多一路 | 32 位 2:1 | **~2** |
| XOR 组合 | 1 位 | ~1 |
| **合计** | | **~5–10 XLR** |

**当前余量 1,283 XLR，完全够。** 但注意 97.89% 时布线易拥塞，可能需要换 seed。

---

## 四、固件方案

### 4.1 UART 非阻塞轮询

BSP 的 `uart_read()` **会阻塞**：
```c
static char uart_read(u32 reg){
    while(uart_readOccupancy(reg) == 0);   // ← 阻塞
    return read_u32(reg + UART_DATA);
}
```

必须用**非阻塞**方式：
```c
if (uart_readOccupancy(BSP_UART_TERMINAL)) {
    char c = (char)read_u32(BSP_UART_TERMINAL + UART_DATA);
    /* 解析命令 */
}
```

`uart_readOccupancy()` 本身就是非阻塞（只读状态寄存器）。**无需改 BSP。**

### 4.2 命令设计

用**单字符命令**，最简单可靠：

| 命令 | 功能 |
|---|---|
| `'1'` | 强制单面板（居中） |
| `'2'` | 强制双面板 |
| `'t'` | 切换（toggle） |
| `'?'` / `'h'` | 打印当前状态 |

**为什么用单字符**：不需要缓冲区、不需要超时、不会误解析。比 `AT+MODE=1\r\n` 之类的协议省事得多。

### 4.3 代码骨架

```c
/* style_driver.c 新增 */
#define STYLE_MODE_REG 0xbcu

void style_apply_mode(int single) {
    video_write(STYLE_MODE_REG, single ? 1u : 0u);
    app_single_panel = single;
}

int style_poll_uart(void) {
    char c;
    if (!uart_readOccupancy(BSP_UART_TERMINAL)) return 0;
    c = (char)read_u32(BSP_UART_TERMINAL + UART_DATA);
    switch (c) {
    case '1': style_apply_mode(1); uart_writeStr(BSP_UART_TERMINAL, "MODE single\r\n"); return 1;
    case '2': style_apply_mode(0); uart_writeStr(BSP_UART_TERMINAL, "MODE dual\r\n");   return 1;
    case 't': style_apply_mode(!app_single_panel); uart_writeStr(BSP_UART_TERMINAL, "MODE toggled\r\n"); return 1;
    case 'h': case '?':
        uart_writeStr(BSP_UART_TERMINAL, app_single_panel ? "MODE single\r\n" : "MODE dual\r\n");
        return 1;
    default: return 0;
    }
}
```

主循环里（`main.c`）：
```c
for (;;) {
    style_poll_uart();          /* 非阻塞，每轮都查 */
    ...
}
```

**注意**：主循环里有 `if (now - last_update < BSP_CLINT_HZ) continue;`，必须在它**之前**调用，否则 1 秒才查一次串口，手感很差。

### 4.4 固件增量

| 项 | 行数 |
|---|---|
| 命令解析函数 | ~25 |
| 寄存器定义 | 2 |
| 主循环调用 | 1 |
| 状态变量 | 1 |
| **合计** | **~30 行** |

---

## 五、完整改动清单

| 文件 | 改动 | 风险 |
|---|---|---|
| `rtl/style/style_accel.sv` | 加 `style_mode_sw` 端口 + APB 寄存器 `0xbc` | 🟢 低 |
| `rtl/style/style_video_system.sv` | 接 `style_mode_sw`，与按键 XOR | 🟢 低 |
| `software/firmware/style_driver.c` | 加 `style_poll_uart()` | 🟢 低 |
| `software/firmware/style_driver.h` | 声明 | 🟢 低 |
| `software/firmware/main.c` | 主循环调用 | 🟢 低 |
| `software/firmware/video_regs.h` | `#define VIDEO_STYLE_MODE 0xbcu` | 🟢 低 |

**RTL 改动只在 APB 层，不碰数据通路** —— 这是低风险的关键。

---

## 六、⚠️ 需要注意的三个点

### 1. 97.89% 资源下的布线风险

上次加消抖（+50 XLR）就导致拥塞失败。**这次只加 5–10 XLR，应该没问题**，但如果失败：
- 换 seed（1→7→13...）
- 或 `MAXB` 8→4 再省 20–30

### 2. 串口与画面上限的冲突

UART 波特率 115200，每字符 ~87µs。**命令解析很轻，不影响帧率。**

但要避免在主循环高频路径里打印 —— 只在收到命令时打一行。

### 3. 按键与串口的语义

用 **XOR** 意味着：
- 串口写 1 后，按键仍能切回双面板
- 串口写 0 后，回到纯按键控制

这是**可预期且不冲突**的。若你希望「串口优先级更高」，改用覆盖而不用 XOR —— 但那样按键会失效，不推荐。

---

## 七、验证计划

| 步骤 | 内容 |
|---|---|
| 1 | iverilog 单元测试：APB 写 `0xbc` → `single_panel` 正确翻转 |
| 2 | 编译验证资源增量（预期 +5–10 XLR） |
| 3 | 上板：串口发 `1` / `2` / `t`，抓图确认画面切换 |
| 4 | 确认按键仍工作（XOR 语义） |
| 5 | 测 fps 有无影响（预期无） |

---

## 八、诚实边界

| 项 | 状态 |
|---|---|
| APB 通路可行性 | ✅ **已读代码确认**（accelerator 直接挂 APB） |
| `0xbc` 地址未被占用 | ✅ **已核对全部已用地址** |
| 资源 5–10 XLR | ◐ **估算，未编译验证** |
| UART 非阻塞可行性 | ✅ **`uart_readOccupancy` 本身非阻塞** |
| 固件 ~30 行 | ◐ **估算** |
| **97.89% 下能否布线** | ⚠️ **未知，可能需要换 seed** |
