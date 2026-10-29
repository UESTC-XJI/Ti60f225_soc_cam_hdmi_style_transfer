# 上板调试 Skill —— Ti60F225 实操手册

> 2026-10-29　硬件侧
> **这份文档是从无数次"板子不响应"里熬出来的。** 每一条都有真实事故对应。
> 目标：让下一个接手的人（或下一个会话的我）**不再重踩这些坑**。

---

## 目录

- [0 三条铁律](#0-三条铁律)
- [1 JTAG / OpenOCD 稳定性（最大的坑）](#1-jtag--openocd-稳定性最大的坑)
- [2 上电恢复标准流程](#2-上电恢复标准流程)
- [3 失败模式全表](#3-失败模式全表)
- [4 冒烟测试三件套](#4-冒烟测试三件套)
- [5 固件与权重验证](#5-固件与权重验证)
- [6 测量口径陷阱（画质数据必读）](#6-测量口径陷阱画质数据必读)
- [7 串口交互](#7-串口交互)
- [8 进程与工具管理](#8-进程与工具管理)
- [9 快速诊断决策树](#9-快速诊断决策树)
- [10 现成工具清单](#10-现成工具清单)

---

## 0 三条铁律

### 铁律一：`pnr PASS` 不等于可用

```
构建 PASS + 时序全正 + 面积更低  ⇒  **仍可能起不来**
```

**真实事故**：撤掉 `style_ddr_profiler`（−418 XLR），构建全绿、零负 slack、
vid slack 反而从 +0.441 变好到 +0.557、面积 98.97% → 98.28%，
**烧上去固件起不来**（CPU PC=0、APB 全返同一值）。换回原版位流立即正常。

**⇒ 每次构建都必须上板 + 跑冒烟测试，不能只看报告。**

### 铁律二：每次上电都要重烧位流

FPGA 的 JTAG 配置是**易失**的。断电后从 **SPI flash 加载旧位流**。

**真实事故**：上电后 UART 显示 `MS 57`，误以为新构建有问题——实际是 flash 里的旧位流（优化前是 57 ms）。

**⇒ 上板第一件事永远是 `python tools/flash_bit.py`。**

### 铁律三：测量数据必须先验证有效性

**真实事故**（一天内三次）：
1. 用坏帧（X 字节非零）做基线 → 风格损失改善虚报 8.0×（实际 2.1×）
2. 忘记 DDR 是偏移二进制（没 `^0x80`）→ 尺度谱 12.6% 虚报成 38.7%
3. 跨场景比较尺度谱 → 同一套权重广角 12.6%、近景 86.5%

**⇒ 任何数字进报告前，先跑第 6 节的口径自检。**

### 铁律四：**画质判断以采集卡为准，不以 DDR 统计为准**

**真实事故（2026-10-29，最深刻的一次）**：

我用「≥25% 画宽累积能量」判断 bank 选型：
- `v8` 输出 **91.7%**（保住大尺度）→ 我判断 v8 更好
- `old` 输出 **20.8%** → 我判断 old 差

**采集卡一看完全相反**：

| | `old` | `v8` |
|---|---|---|
| DDR 尺度谱 | 20.8%（差） | **91.7%（好）** |
| **采集卡视觉** | **蓝调、纹理一致、像铅笔版画** | **橄榄绿 + 大片平坦色块，像色阶化** |
| 内容保真（模型侧） | **0.460** | 0.359 |
| 时间稳定性 | **26.5 dB** | 19.9 dB |

**"保住大尺度能量"在数值上好听，视觉上却是"大片平坦色块"——那叫色阶化，不叫画。**

**⇒ 验收顺序必须是：**
```
1. 采集卡抓图（人眼看）        ← 最终真相
2. 内容保真 / 时间稳定性        ← 客观支撑
3. DDR 统计（PSNR/SSIM/尺度谱） ← 只能做"差异描述"，不能当画质判据
```

**为什么 DDR 统计不够**：它不经过显示链。显示屏还有
`rgb_gain` + `luma_tone_map` + `lift` 三级处理，会显著改变观感。
同一帧：DDR 口径 ≥25% 画宽 = 12.6%，**屏幕观感 = 62.4%**。

**采集卡抓图命令**（见 §6.8）。

---

## 1 JTAG / OpenOCD 稳定性（最大的坑）

### 1.1 症状：`mpsse_flush()` 卡死

OpenOCD 日志出现：

```
Warn : Haven't made progress in mpsse_flush() for 2001ms.
Warn : Haven't made progress in mpsse_flush() for 4001ms.
...
Warn : Haven't made progress in mpsse_flush() for 256001ms.
```

然后 OpenOCD **静默退出**（端口 4444 消失）。

**根因**：FTDI 的 MPSSE（JTAG 引擎）在**大块内存读取**上会停滞。
`dump_image` 读 307 KB 时特别容易触发。

**为什么之前有时能成**：默认 JTAG 时钟只有 **800 kHz**（`debug_ti.cfg:38`），
读 307 KB 需要 3 秒以上；FTDI 的缓冲在长传输里会堵。

### 1.2 解决方案（两个一起用才稳定）

**① 把 JTAG 时钟提到 6 MHz**

```bash
openocd -f software/bsp/EfxSapphireSoc/openocd/ftdi_ti.cfg \
        -f software/bsp/EfxSapphireSoc/openocd/debug_ti.cfg \
        -c "adapter speed 6000"
```

验证：
```
> adapter speed
adapter speed: 6000 kHz
```

**② 分块读取（每块 32 KB）**

不要一次 `dump_image` 读 307 KB，用 `_ocd.py` 的 `dump()`：

```python
from _ocd import OCD
o = OCD()
o.cmd('halt')
o.dump('_m/frame.bin', 0x05800000, 0x4B000)   # 内部按 32KB 分块
o.cmd('resume')
```

**实测效果**：307 KB 帧 dump 从"必然卡死"变成 **稳定 30 秒完成**。

### 1.3 症状：多个 openocd 抢 FTDI

```
Error: no device found
Error: unable to open ftdi device with vid 0403, pid 6011 ...
```

但 `flash_bit.py --list` **能看到设备**。

**根因**：上一次的 openocd 没退干净，还占着 FTDI。

**解决**：
```bash
taskkill //F //IM openocd.exe
sleep 5           # 必须等，FTDI 句柄释放需要时间
# 再启动
```

**检查是否有残留**：
```bash
powershell.exe -NoProfile -Command "Get-Process -Name openocd -ErrorAction SilentlyContinue | Select-Object Id"
```

### 1.4 症状：`Can't communicate with the CPU`

```
Info : JTAG tap: fpga_spinal.bridge tap/device found: 0x10660a79  ← TAP 找到了
Error: Can't communicate with the CPU
Warn : target fpga_spinal.cpu0 examination failed
```

**含义**：JTAG 链通了（能看到 Efinix Ti60 的 IDCODE），但 **CPU 不响应**。

**两种原因，处置不同**：

| 原因 | 判断 | 处置 |
|---|---|---|
| **位流没配好**（最常见） | `style CORE_ID = 0` | **重烧位流** |
| 固件跑飞 | `style CORE_ID = 0x3154534e` 但 PC=0 | 重烧固件 |

**恢复顺序（按顺序试，每步之后验证）**：
```
1. taskkill openocd → sleep 5 → 重烧位流 → 重启 openocd
2. 还是不行 → 让用户拔插 USB 或断电重上电
3. 还是不行 → 检查 USB 线/供电
```

### 1.5 正确的 OpenOCD 后台启动方式

**❌ 错误**：从 `win_bash` 用 `&` 后台启动
→ **shell 超时（300 s）时会被一起杀掉**

**❌ 错误**：`cmd //c start "ocd" /B ...`
→ MSYS bash 下引号解析失败（`系统找不到文件 ocd`）

**❌ 错误**：`Start-Process -RedirectStandardOutput ...`
→ PowerShell 会阻塞等待

**✅ 正确**：用工具的后台 job 机制

```
win_bash(command="openocd ...", run_in_background: true)
```
或 `nohup` 风格。**job 进程能活过 shell 重启。**

---

## 2 上电恢复标准流程

```bash
# ── 步骤 0：清场 ──────────────────────────────
taskkill //F //IM openocd.exe
sleep 5
taskkill //F //IM WindowsCamera.exe     # 采集卡被占用会导致 ffmpeg 抓图失败

# ── 步骤 1：确认设备在 ─────────────────────────
python tools/flash_bit.py --list
#   期望：发现 2 个可用 URL ftdi://0x0403:0x6011:1:4/1 和 /2
#   注意：URL 里的 1:3 / 1:4 会随 USB 枚举变化！

powershell.exe -NoProfile -Command "[System.IO.Ports.SerialPort]::GetPortNames()"
#   注意：COM 号会变（见过 COM13/14/17/18）

# ── 步骤 2：烧位流 ────────────────────────────
python tools/flash_bit.py                       # 烧 _bit_frozen/ 下的冻结副本
#   期望：✅ 烧录成功 + Device ID read from JTAG: 0x10660A79 + finished with JTAG programming

# ── 步骤 3：起 OpenOCD（后台 job + 6 MHz）──────
openocd -f .../ftdi_ti.cfg -f .../debug_ti.cfg -c "adapter speed 6000"
#   等 18-20 秒
#   期望：Target successfully examined + Listening on port 4444

# ── 步骤 4：烧固件 ────────────────────────────
> reset halt
> load_image {elf}          # 期望 "downloaded ... bytes"
> reg pc 0x1000
> resume

# ── 步骤 5：等够时间！────────────────────────
sleep 20~25                 # ⚠ 见 5.3：不要提前 dump

# ── 步骤 6：冒烟测试 ──────────────────────────
python tools/smoke_test.py
#   必须三条全过才继续
```

---

## 3 失败模式全表

| # | 症状 | 根因 | 处置 | 隐蔽度 |
|---|---|---|---|---|
| 1 | `pnr PASS` 但 vid slack 为负 | 时序不满足 | 看 `build_check.py` 裁决 | 低 |
| 2 | 面积 >99.1% 布线失败 | PnR 概率性 | 降面积或重建 | 低 |
| 3 | **构建全绿但固件起不来** | 未知（疑似 DDR 裕量） | **重烧/回退** | **极高** |
| 4 | CPU PC=0、CORE_ID=0 | 位流没配好 | 重烧位流 | 中 |
| 5 | `mpsse_flush` 卡死 | 大块 JTAG 读 + 低时钟 | **6 MHz + 分块** | **高** |
| 6 | `no device found` 但 list 能看到 | 多个 openocd 抢 FTDI | `taskkill` + `sleep 5` | 中 |
| 7 | UART 无输出 | COM 号变了 | 重新枚举串口 | 中 |
| 8 | 串口打不开 | 被别的东西占用 | 关闭摄像头软件/其它终端 | 中 |
| 9 | MD5/XOR 对不上 | loader 吃了部分 | 核实大小 | 低 |
| 10 | **dump 的帧 X 字节非零** | 读到的是半写/旧帧 | **重新 dump** | **高** |
| 10b | **源帧渲染成绿底/品红** | **对源帧多做了 `^0x80`** | **源帧不取反** | **极高** |
| 11 | 测出的数字和上次差很多 | **场景/光照变了** | 同场景重测 | **极高** |
| 12 | 刚 load_image 就 dump | bank 编程还没完成 | **等 20~25 s** | **高** |

---

## 4 冒烟测试三件套

**每次烧录后必做。** `tools/smoke_test.py` 已实现：

```
① resume 后 2 秒 reg pc != 0            → CPU 在跑
② mdw 0xf8100000 == 0x4f534431          → video 核在
   mdw 0xf8100200 == 0x3154534e          → style 核在
③ mdw 0x1000 == ELF 首字                 → DDR 读写正确
```

**第 ③ 条最关键**——它能抓到 DDR 裕量问题，而 ①② 抓不到。

**实战记录**：这个工具上线后第一次跑，就抓到了 CPU PC=0 / CORE_ID 全 0 的失败状态。

退出码 0/1，可直接接进脚本。

---

## 5 固件与权重验证

### 5.1 XOR 身份校验（唯一可靠的身份判定）

**不要用文件名、时间戳、大小判断是哪套权重。** 用 XOR。

```python
# 固件构建时会打印
PASS complete application: ...elf  [weights XOR=0x9237f8f6]
```

```bash
# 从 DDR 读回验证
> mdw 0x06F00000 903        # 然后算 XOR
```

或者直接**逐字节比对**（比 XOR 更强）：
```python
dd = np.fromfile('_m/weights.bin', dtype=np.uint8)
ref = np.fromfile('weights/<name>/rowpipe_blob.bin', dtype=np.uint8)
assert (dd == ref).all()
```

### 5.2 权重在 DDR 的位置

| 内容 | DDR 地址 | blob word 偏移 |
|---|---|---|
| blob 基址 | `0x06F00000` | 0 |
| **L11 bias R/G/B** | `0x06F037A0/A4/A8` | **3560/3561/3562** |
| L11 M[0..2] | `0x06F037E0/E8/F0` | **3576/3578/3580** |
| L11 Q 头 | `0x06F03860` | 3608 |

blob 总计 14,448 B = 903 beat = 3,612 word。

### 5.3 ⚠ 不要刚 load_image 就 dump

**真实事故**：DC 校准后立刻 dump，测出 q = +15.4（和校准前一模一样），
误判"DC 没生效"。**实际是固件还没跑完 `style_program_bank(0)` 的权重拷贝。**

后来直接读 DDR 确认：`0x06F037A0 = fffff559 000029fc 000040f4` = **新 DC 值 ✓**

**⇒ load_image 之后等 20~25 秒再 dump。**

### 5.4 DC 校准循环

**目标**：`目标 q = 参考图通道均值 − 128`

**换算**：`Δbias = Δq × 2^shift / M`

**循环**：
```
1. 把未校准的 blob 编进固件，上板
2. dump 一帧，量 q = 各通道均值 − 128（注意 `^0x80`！）
3. Δq = 目标 − 实测；Δbias = Δq × 2^shift/M
4. python tools/freeze_dc.py <blob> <new_bias_R> <new_bias_G> <new_bias_B> ...
5. 重新编固件，上板，复测
6. 误差 < 3 级即收敛
```

**实测例子（xxg640）**：
- 参考画 `starry_night_xx.jpg` 均值 80.4/104.3/131.2 → 目标 q = −47.6/−23.7/+3.2
- 未校准实测 q = +15.5/+9.7/+10.4（**不是 0！模型侧的"零中心"是针对他们的场景**）
- Δq = −63.1/−33.3/−7.2；2^37/M = 203.28 → Δbias = −12825/−6778/−1463
- 原 bias 10098/17526/18091 → 新 bias **−2727/10748/16628**
- XOR: `0x6dc84108` → **`0x9237f8f6`**

---

## 6 测量口径陷阱（画质数据必读）

### 6.1 ⚠⚠ **两个帧的编码约定不同**（最容易搞错的一条）

**这是 2026-10-29 才发现的，它让之前一批测量全部作废。**

```verilog
// rtl/style/style_display.sv:132
wire [31:0] rgb = {8'b0, right_side ? (rd_pixel[23:0]^24'h808080)
                                     : rd_pixel[23:0]};
```

**`^0x80` 只作用于 `right_side`（风格结果），左侧原画不做。**

| 帧 | 地址 | 编码 | 正确处理 |
|---|---|---|---|
| **源帧**（原画） | `0x05000000` | **普通 8-bit BGRX** | **不做 `^0x80`** |
| **结果帧**（风格） | `0x05800000` | **偏移二进制 BGRX** | **必须 `^0x80`** |

```python
# 结果帧（风格）
d = np.fromfile(p, dtype=np.uint8)[:w*h*4].reshape(h, w, 4)
img_result = d[:, :, :3] ^ 0x80

# 源帧（原画）—— 不取反！
img_source = d[:, :, :3]
```

**对源帧做了 `^0x80` 会怎样**：画面出现**绿色背景 + 品红色高光 + 严重色阶化**，
统计上 σ 从 75 变 64、大尺度能量从 93.1% 变 83.1%。

**真实事故**：我一直对两个帧都做 `^0x80`，导致：
- 源帧渲染出来是"绿底+品红"的损坏图（我误以为是"场景变了"或"坏帧"）
- **同场景尺度谱测出 −2.1 点（几乎不变）**，而正确口径是 **−74.2 点**

**⇒ 判断口径对不对的最快方法：渲染源帧看一眼。正常应该是干净的相机画面。
出现绿底/品红 = 多做了 `^0x80`。**

### 6.2 合法帧必须 X 字节全 0

```python
d = np.fromfile(p, dtype=np.uint8)[:w*h*4].reshape(h, w, 4)
assert (d[:, :, 3] == 0).all(), "不是合法 BGRX 帧"
```

**真实事故**：`src_full.bin` 有 305,478/307,200 个 X 非零 ⇒ 整帧是坏的，
基于它算的所有基线数字作废（害我虚报 8.0×）。

### 6.3 参照图交叉校验（最好的自检）

**任何尺度谱测量前，先算参照图**：

```
starry_night.jpg 的「≥25% 画宽累积能量」应 ≈ 88.5%（误差 <1 点）
```

算不出来就说明口径错了。

### 6.4 只能做「同输入 A/B」

**跨内容比较无效**：我们的输出（设备场景）vs 参考画（梵高油画）—— 差异主要来自"画的是什么"。

**跨场景比较无效**：同一套权重，广角场景 12.6%、近景场景 86.5%。

**跨会话比较无效**：光照变了、AGC 档位变了，所有亮度相关指标都不可比。

### 6.5 工具已知偏差

| 工具/函数 | 偏差 | 影响 |
|---|---|---|
| `cumulative_at(p, k)` 用 `p[:k]` | **off-by-one**（含 DC、漏边界 bin k） | 绝对值**系统性偏低 ~4 点**；正确是 `p[1:k+1]` |
| `fwhm_px` | 返回**半高半宽（HWHM）**、在 256 缩略图上算 | **低估"变糊"约 4.3 倍** |

**好消息**：delta 里两边同样偏低会抵消 ⇒ **相对结论仍成立**。
**但报绝对值必须注明口径。**

### 6.6 bank 切换后要等 settle

**真实事故**：切到 bank1 后立刻抓帧，测出 16×16 块时间 PSNR 只有 **16.17 dB**
（以为 old 极不稳定）。**延长 settle 到 5 秒后重测 → 42.8 dB**。

**⇒ 每次 `style_switch_bank` 之后等 2.6 s（固件内部等待）+ 额外 5 s 再测。**

### 6.7 采集卡截图 vs DDR dump 不可直接比
### 6.8 采集卡抓图（画质判断的最终依据）

```bash
FF="/d/Program Files/JianyingPro/7.7.0.12666/ffmpeg.exe"   # 或任意 ffmpeg

# 0) 先关摄像头软件（会独占采集卡）
taskkill //F //IM WindowsCamera.exe

# 1) 抓一帧
"$FF" -hide_banner -loglevel error -f dshow -i "video=USB Video" \
      -frames:v 1 -update 1 -y ../demo/_grab/cap.png

# 2) 裁出左右面板做并排对比
python - <<'PY'
from PIL import Image
import numpy as np
def crop_right(p):
    im=Image.open(p).convert('RGB'); a=np.asarray(im)
    rows=np.where(a.max(axis=(1,2))>20)[0]; cols=np.where(a.max(axis=(0,2))>20)[0]
    y0,y1=rows[0],rows[-1]; x0,x1=cols[0],cols[-1]
    mid=x0+(x1-x0+1)//2
    return im.crop((mid,y0,x1,y1+1))
PY
```

**注意事项**：
- **必须关掉 Windows 相机等软件**，否则设备被独占，ffmpeg 报错
- 采集卡输出是 **1920×1080**（HDMI 720p 被放大），实际内容区约 1920×728
- **不要拍屏**（摩尔纹 + 反光 + 帧率不同步）



截图经过了 `rgb_gain` + `luma_tone_map` + `lift`，对比度被抬高。
同一帧：DDR 口径 ≥25% 画宽 = 12.6%，屏幕观感 = 62.4%。

**两者都不是错的，但必须写明是哪个口径。**

---

## 7 串口交互

### 7.1 COM 号会变

见过：COM13/14、COM17/18。USB 重枚举后会变。

**每次先枚举**：
```bash
powershell.exe -NoProfile -Command "[System.IO.Ports.SerialPort]::GetPortNames()"
```

### 7.2 用脚本文件，不要内联 PowerShell

内联的引号转义极易出错。**写成 `.ps1` 文件再执行**：

```powershell
# _uart.ps1
$p = New-Object System.IO.Ports.SerialPort('COM13', 115200, 'None', 8, 'One')
$p.ReadTimeout = 300
$p.Open()
$p.Write('1')                      # 发命令（单字符）
Start-Sleep -Milliseconds 2600     # 等 bank 切换完成
$p.Close()
```

```bash
powershell.exe -NoProfile -ExecutionPolicy Bypass -File _uart.ps1
```

### 7.3 收日志

```bash
powershell.exe -NoProfile -Command "\$p=New-Object System.IO.Ports.SerialPort('COM13',115200,'None',8,'One'); \$p.ReadTimeout=200; \$p.Open(); \$sw=[System.IO.StreamWriter]::new('log.txt',\$false); \$sw.AutoFlush=\$true; \$e=(Get-Date).AddSeconds(10); while((Get-Date) -lt \$e){ if(\$p.BytesToRead -gt 0){ \$b=New-Object byte[] \$p.BytesToRead; \$n=\$p.Read(\$b,0,\$b.Length); \$sw.Write([Text.Encoding]::ASCII.GetString(\$b,0,\$n)) } else { Start-Sleep -Milliseconds 40 } }; \$p.Close(); \$sw.Close()"
```

### 7.4 UART 命令表（当前固件）

| 命令 | 作用 |
|---|---|
| `s` / `S` / `?` | 列出风格库，`*` 标当前 |
| `1`..`4` | 切到对应 bank |

**⚠ 当前固件没有按键/旋钮切风格** —— 开机固定加载 bank0（编译进去的
`rowpipe_weights.h`），风格切换只有 UART。板上的物理按键只切**显示模式**
（并排 ↔ 单画面），不切风格。

---

## 8 进程与工具管理

### 8.1 后台进程会随 shell 超时死掉

`win_bash` 的持久 shell 有 **300 秒超时**。超时后：
- shell 被停止
- **从它启动的所有后台进程（`&`）一起被杀**

**⇒ 需要长期运行的进程用工具的后台 job**（`run_in_background: true`）。

### 8.2 常见命令陷阱

| 命令 | 问题 | 正确做法 |
|---|---|---|
| `timeout 120 git push` | **Windows 的 TIMEOUT.EXE**，不是 GNU timeout | 直接跑，或用 job |
| `sha256sum` | MSYS 里没有 | 用 Python `hashlib` |
| `stat -c%s` | 有时不可用 | `wc -c < file` |
| `powershell ... \$var` | bash 会吃 `$` | 用单引号包或写 `.ps1` |
| `cmd //c "_b.bat"` | 正确（MSYS 需要 `//c`） | ✅ |

### 8.3 构建

```bash
cmd //c "_b.bat"          # Efinity 全流程，约 15 分钟
```
**必须用 `run_in_background: true`**，否则 300 秒超时会杀掉构建。

构建完成后：
```bash
python tools/build_check.py     # 裁决 + XLR/RAM/slack
```

---

## 9 快速诊断决策树

```
板子不响应
├─ flash_bit.py --list 能看到 FTDI 吗？
│  ├─ 不能 → USB/供电问题 → 拔插/换线/问用户
│  └─ 能 ↓
├─ openocd 能启动吗？
│  ├─ "no device found" → 多个 openocd 抢占 → taskkill + sleep 5
│  ├─ 能启动 ↓
├─ "Target successfully examined" 吗？
│  ├─ 不是（Can't communicate with CPU）↓
│  │  ├─ mdw 0xf8100200 == 0x3154534e？
│  │  │  ├─ 不是 → 位流没配好 → **重烧位流**
│  │  │  └─ 是 → 固件跑飞 → 重烧固件
│  └─ 是 ↓
├─ 烧固件失败？
│  ├─ "downloaded" 不出现 → 检查 ELF 路径/大小
│  └─ 成功 ↓
├─ 冒烟测试
│  ├─ ① PC=0 → 固件没跑 → 重烧固件，仍不行查 ELF 装载地址
│  ├─ ② CORE_ID 错 → 位流不对
│  ├─ ③ DDR 读回不符 → **DDR 裕量问题** → 换位流版本
│  └─ 全过 ↓
└─ UART 有输出？
   ├─ 没有 → COM 号变了 / 被占用 / 固件卡在早期初始化
   └─ 有 → 正常，开始测
```

**dump 卡死/超时**：
```
├─ OpenOCD 日志有 "Haven't made progress in mpsse_flush"？
│  └─ 是 → JTAG 时钟太低/块太大 → **adapter speed 6000 + 分块 32KB**
└─ 无日志但端口消失 → OpenOCD 崩了 → 重启
```

**测出的数字异常**：
```
├─ X 字节非零？ → 坏帧，重 dump
├─ 和上次差很多？ → 场景/光照/AGC 变了 → 同场景重测
├─ 第 4 字节（X）全 0 但 Q 值离谱？ → 忘了 ^0x80
├─ 刚切换 bank？ → 等 5 s settle 重测
└─ 刚 load_image？ → 等 25 s 让 bank 编程完成
```

---

## 10 现成工具清单

| 工具 | 用途 |
|---|---|
| `tools/flash_bit.py` | 烧位流，自动发现 FTDI URL，默认烧 `_bit_frozen/`。`--list` 列设备，`--file` 指定文件，`--outflow` 烧构建产物 |
| `tools/smoke_test.py` | **烧录后三件套**，退出码 0/1 |
| `tools/build_check.py` | 构建裁决：阶段 + slack 符号 + 面积。**必须看它，不能只看 pnr PASS** |
| `tools/build_firmware.sh` | 固件构建，打印 XOR |
| `tools/freeze_dc.py` | DC 固化（只改 L11 bias 3 个 word，其余逐字不动），支持 `--dry-run` |
| `tools/style_metrics.py` | PSNR / SSIM（纯 numpy），支持 `--psnr-min/--ssim-min` + 退出码 |
| `tools/style_loss_metric.py` | 训练同款 VGG Gram 风格损失 |
| `tools/style_probe.py` | DDR/APB 探针（`stats` / `slots` / `weights` / `l11` / `gains` / `dup`） |
| **`_ocd.py`** | **本次新增**：健壮的 OpenOCD telnet 助手，含**分块 dump**（解决 mpsse 卡死） |

### `_ocd.py` 用法

```python
import sys; sys.path.insert(0, '.')
from _ocd import OCD

o = OCD()                       # 自动连 127.0.0.1:4444
print(o.cmd('adapter speed'))   # 查时钟
print(o.read_words(0x06F037A0, 3))   # 读 3 个字
o.cmd('halt')
o.dump('_m/frame.bin', 0x05800000, 0x4B000)   # 分块 dump 307KB
o.cmd('resume')
o.close()
```

命令行：
```bash
python _ocd.py status
python _ocd.py dump _m/f.bin 0x05800000 0x4B000
```

---

## 附 A 关键地址速查

| 项 | 地址 |
|---|---|
| style APB 基址 | `0xF8100200` |
| style CORE_ID | `0xF8100200`（应 `0x3154534e`） |
| stream_enable | `0xF8100204`（bit4 采集+任务，bit0 手动起帧） |
| captured / dropped / inferred | `0xF8100238` / `0x3C` / `0x40` |
| video APB 基址 | `0xF8100000` |
| video CORE_ID | `0xF8100000`（应 `0x4f534431`） |
| **raw_frames（传感器真实帧率）** | **`0xF8100150`** |
| 源帧基址 | `0x05000000`（640×480×4 = `0x12C000`） |
| **结果帧基址** | **`0x05800000`**（**320×240×4 = `0x4B000`**，A-4 之后） |
| 结果帧 slot 步长 | `0x140000`（6 个 slot 轮转） |
| 权重 blob | `0x06F00000`（903 beat / 14,448 B） |
| L11 bias | `0x06F037A0/A4/A8` |
| L11 M | `0x06F037E0/E8/F0` |

---

## 附 B UART 日志字段速查

```
MONET CAP 31 NN 30 DISP 0 DROP 0 MS 27 ERR 0
        │    │     │        │    │
        │    │     │        │    └ 引擎错误数
        │    │     │        └ 推理耗时 ms
        │    │     └ 采集丢帧数（应恒 0）
        │    └ 推理帧数
        └ 采集帧数（≈ 传感器帧率）

3A state 1 expL 1114 expH 1 vts 1457 mean 112 hot 284 goal 112 hold 1 ... agc 0 agcN 0
                                          │        │         │          │
                                          │        │         │          └ AGC 档位/动作数
                                          │        │         └ 测光目标
                                          │        └ 高光占比‰
                                          └ 平均亮度（与帧均值 177 不是一回事！）

DDR100M T ... RPMS 8 CPMS 18 PF 14197 PFC 14197 WW 9
                        │    │    │          │
                        │    │    │          └ 预取完成数（应 == PF）
                        │    │    └ 预取发起数
                        │    └ 算力周期（= 帧时 − RPMS，恒等式）
                        └ 读等待周期

VIDEO UF 0 DUF 0 DDROP 0 FAULT 0 CSI 0 DME 0 IERR 0 AXI 0 SW 0 SWT 0 SWE 0
      │   │    │       │       │   │    │      │    │   │    │
      │   │    │       │       │   │    │      │    │   │    └ 切换错误数
      │   │    │       │       │   │    │      │    │   └ 切换耗时 ms
      │   │    │       │       │   │    │      │    └ 切换次数
      │   │    │       │       │   │    │      └ AXI 错误
      │   │    │       │       │   │    └ 显示 DMA 错误
      │   │    │       │       │   └ DME 错误
      │   │    │       │       └ CSI 错误
      │   │    │       └ 采集故障
      │   │    └ 显示丢帧
      │   └ 显示欠载
      └ 上溢
```

**单位陷阱**：`expL` 是**行**、`expH` 是**半行奇偶**、`vts` 是**行**。
曝光上限 = `2×VTS − 11`（半行）。曾误读为"exp 4989 > vts 2500 = 曝光超帧长"，
实际 4989 半行 = 2494.5 行 < 2500 行，没超。

---

## 附 C 本次会话踩坑时间线（教训索引）

| 时间 | 事故 | 学到什么 |
|---|---|---|
| 10-27 | `IDXW=6` 写死，改 DEPTH 后指针回绕 | 参数化所有依赖 DEPTH 的量 |
| 10-27 | `p0..p3` 用 `reg`+`always @*`，敏感表不全 | 组合逻辑用 `wire` |
| 10-27 | A-3 垂直复制 bug（奇行 384~512 垃圾像素） | 仿真必须用生产几何 |
| 10-28 | B-1 实验被上述 bug 污染，误判"读侧无余量" | 实验前先确认环境干净 |
| 10-28 | 优化算力但帧率不变 | **先诊断瓶颈再优化**（读 `raw_frames`） |
| 10-28 | TAIL_LOWRES=0 布线失败（99.10%） | 99% 是概率区 |
| 10-28 | 撤 profiler −418 XLR，全绿但起不来 | `pnr PASS` ≠ 可用 |
| 10-28 | 上电后 `MS 57` | 必须重烧位流 |
| 10-28 | 风格损失虚报 8.0× | 基线帧必须先验 X 字节 |
| 10-28 | 尺度谱 38.7% 虚报 | DDR 是偏移二进制，必须 `^0x80` |
| 10-29 | 尺度谱跨内容比较 | 同一套权重不同场景差 7 倍 |
| 10-29 | bank 切换后立刻测，16.17 dB | 等 settle |
| 10-29 | **DC 后立刻 dump，误判"没生效"** | **等 20~25 s** |
| 10-29 | `mpsse_flush` 卡死 | **6 MHz + 分块读** |
