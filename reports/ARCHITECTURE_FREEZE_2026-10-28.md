# 架构冻结 · 2026-10-28

> **目的**：把 31 fps / 30 fps 达标的稳定状态锁住，作为后续所有工作的基线。
> **原则**：任何改动前先读这份；任何搞不清风险的改动都不做。

---

## 一 冻结的是什么

| 项 | 值 | 怎么验证 |
|---|---|---|
| **位流** | `_bit_frozen/ti60f225_oob.bit`，3,229,989 B，sha256 `5a7d9d08…` | `python tools/flash_bit.py` 会打印 sha |
| **XLR** | **60,171 / 60,800（98.97%）**，余量 **629** | `python tools/build_check.py` |
| **RAM** | 202 / 256，余量 **54** | 同上 |
| **DSP** | 147 / 160 | 同上 |
| **时序** | vid_clk_dvi2 **+0.441**、core_clk +2.032、hdmi_tx_slow +5.787、**sdram_clk +0.135（最紧）** | 同上 |
| **配置** | CI/CO=8 + TAIL_LOWRES=1 + A-1 + A-2 + A-4 | `rtl/style/style_accel.sv` |
| **固件** | starry_old_signed_dc（XOR `0xb995616f`）+ VTS 1457 + AGC 起点 6.160× | UART 日志 |
| **实测** | **CAP 31 / NN 30~31 / DROP 0 / UF 0 / FAULT 0 / MS 26~27 / 链路全零** | UART `MONET` + `VIDEO` 行 |

---

## 二 上板标准流程（**每次上电都要做**）

**FPGA 重新上电会从 SPI flash 加载旧位流**——已踩过：`MS 57` 就是旧位流的时序。

```
1. python tools/flash_bit.py          # 烧 _bit_frozen 的 A-4 版
2. OpenOCD → reset halt → load_image {elf} → reg pc 0x1000 → resume
3. UART 确认：CAP≈31 / NN≈31 / DROP 0 / MS≈26
```

### ⚠ 必须做的冒烟测试（今天新增，血的教训）

只看 UART 不够——已发生过**构建全绿、时序全正、面积更低，但板子起不来**的事故。

```
① resume 后 2 秒 reg pc != 0
② mdw 0xf8100000 == 0x4f534431     # video 核活着
   mdw 0xf8100200 == 0x3154534e     # style 核活着
③ mdw 0x1000 == ELF 首字             # DDR 读写正确 ← 这条最关键
```

第 ③ 条能直接暴露 DDR 裕量问题，而 ①② 抓不到。

---

## 三 已知的三个失败模式（按隐蔽程度）

| # | 现象 | 能否用现有手段抓到 |
|---|---|---|
| 1 | `pnr PASS` 但 vid slack **−0.710 ns** | ✅ `build_check.py` 看 slack 符号 |
| 2 | 面积 99.41% **布线失败** | ✅ 阶段结果 |
| 3 | **全 PASS + 全负 slack 为零 + 面积更低，但固件起不来** | ❌ **只能靠上板冒烟测试** |

第 3 类实例：撤掉 `style_ddr_profiler`（−418 XLR，XLR 59,753 / 98.28%、零负 slack、
vid +0.557 反而变好）⇒ 烧上去 **CPU PC=0、APB 全返同一值**。换回本冻结位流立即正常。

**疑似根因**：`sdram_clk` 裕量变薄（+0.135 已是最紧），而固件跑在 DDR 上。
**⇒ 任何可能扰动全局布局的改动，都要有上板失败的预案。**

---

## 四 明确不做的事（都已验证过，不要重试）

| 方向 | 为什么 |
|---|---|
| **撤 profiler / 任何"纯删除腾面积"** | 已实测导致板子无法启动 |
| **TAIL_LOWRES=0（L11 全分辨率）** | XLR 60,253 (99.10%) ⇒ **布线失败**；且 +4.66 ms ⇒ 31→27 fps |
| **层融合（Tier 3）** | 收益仅 ~1 ms（L3~L9 只占 14.7% 组），面积缺口 4 倍，结构性重写 |
| **720p 处理** | 算力 47.8 ms vs 预算 33.3 ms，三条独立的墙（算力/时钟/DSP） |
| **显示端换插值** | 四种插值只把特征尺度 2→3 px（目标 160~320 px） |
| **调量化救画质** | 量化 SQNR 36~46 dB，对高频贡献 0.002% |
| **压低 VTS 提帧率** | 会导致丢帧（违反"不丢帧"），且曝光上限等比下降 |

---

## 五 允许的改动范围

### ✅ 安全（不碰 RTL datapath）

- 固件（`software/firmware/`）：AGC、3A、日志
- 报告 / 文档 / 工具
- 权重与 DC 标定（只改 blob，不改 RTL）
- 演示材料

### 🟡 需谨慎（要构建 + 上板冒烟）

- `rtl/style/style_display.sv`（显示域 slack 宽松：core +2.032 / hdmi +5.787）
- `video_apb_ctrl.sv` 加寄存器
- 任何**不改变资源总量**的局部改动

### ⛔ 高风险（除非有明确的收益和完整预案）

- `rowpipe_layer.v`（32,079 XLR 的主体，vid 域 +0.441 ns）
- `rowpipe_engine.v` / `rowpipe_frame_driver.v`
- 任何会让 XLR > 60,200 或让 sdram_clk slack 变薄的改动

---

## 六 并行协作约定

- **`software/firmware/`**：队友在做 C1 多风格切换。**硬件侧不要碰 `main.c` / `style_driver.c`**。
  3A 相关文件（`camera_3a.c` / `camera_ae.c` / `camera_3a.h`）由硬件侧负责。
- **权重与 `export_*`**：模型侧会重写。`rowpipe_weights.h` 是**构建产物，永不手改**。
  身份用 **XOR 校验**确认，不用文件名/时间戳。
- **构建**：同一时刻只允许一个 `_b.bat`。

---

## 七 冻结状态的完整备份

| 位置 | 内容 |
|---|---|
| `_bit_frozen/ti60f225_oob.bit` | 可工作位流（sha `5a7d9d08`） |
| `_backup_20261028_30fps/` | 30 fps 定版全量备份（162 文件 / 6 MB，含 sha256 清单） |
| `_backup_20261028_tier3_base/` | Tier 3 动手前基线（913 文件 / 42 MB，含 git archive + RTL 快照） |
| 仓库外副本 | 两份都在 `../` 下各有一份 |

**回退三级**：
```bash
# ① 只回退源码
cp -r _backup_20261028_tier3_base/rtl/accel_rowpipe _backup_20261028_tier3_base/rtl/style rtl/
# ② 源码 + 现成位流（不等构建）
cp _backup_20261028_30fps/bit/ti60f225_oob.bit _bit_frozen/ && python tools/flash_bit.py
# ③ 完全回退到 git
git checkout -- rtl/ && git status
```

---

## 八 冻结后硬件侧的优先级

| 序 | 事项 | 依赖 |
|---|---|---|
| 1 | **C1 配合验证**（帧边界切换、不丢帧） | 队友 |
| 2 | **C3 材料补完**（PSNR/SSIM 需模型侧 float 参考） | 模型侧 |
| 3 | **演示材料**（彩图/人脸/风景、按键切风格录像） | 板子 |
| 4 | **dilation 接口设计**（见 `DILATION_DESIGN_SPEC.md`，**只设计不实现**） | 模型侧决策 |
| 5 | 冒烟测试脚本化 | 无 |
