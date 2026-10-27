# 给模型侧：怎么改「呐喊 / redsky」风格固件

> 2026-10-27　板侧/RTL 侧 → 模型/训练侧
> 面向：你要自己换权重、自己出固件、自己烧板验证。
> 本文所有命令都在 `rowpipe_keys/` 目录下执行（板侧仓库根）。

---

## 〇、当前板子状态（先对齐事实）

| 项 | 值 |
|---|---|
| 风格 | **redsky v5**（呐喊），权重 XOR = `0xcbc67865`，3612 字 |
| 位流 | Track1 C 档（posted-B 写引擎 + 显示读优先级 + 64 拍 burst） |
| 固件 | 本仓库 `software/firmware/build/soc_video_app.elf`，含 v5 权重 |
| 相机增益 | **R 400 / G 256 / B 414**（24 色卡校准后的值，见 §七） |
| 实测 | 50 ms/帧、17-18 fps、`AXI` 错误 0、`DROP` 0 |

---

## 一、一句话流程

```
改 software/firmware/rowpipe_weights.h  →  bash tools/build_firmware.sh
→ 烧 ELF → 看串口三行
```

你**只需要动一个文件**：`software/firmware/rowpipe_weights.h`。其他（固件逻辑、RTL、位流）都不用碰。

---

## 二、权重文件长什么样

```c
#define ROWPIPE_WEIGHT_WORDS 3612u
#define ROWPIPE_WEIGHT_XOR   0xcbc67865u        // 必须与数组内容自洽

static const uint32_t rowpipe_weights[3612] = { 0x... };
```

- **3612 字 = 14,448 B**（12 层 blob，每层 `ci*9 + 13` 个 32 位字，见 `reports/FOR_MODEL_QUANT_CONTRACT.md`）
- `ROWPIPE_WEIGHT_XOR` 是全部 3612 字异或的结果，固件开机自检用。**改了数组就必须重算**，否则自检失败、权重不加载。
- 算 XOR 的方法：

```python
import re, functools
s = open('software/firmware/rowpipe_weights.h', encoding='utf-8', errors='ignore').read()
m = re.search(r'rowpipe_weights\s*\[[^\]]*\]\s*=\s*\{(.*?)\};', s, re.S)
v = [int(t.rstrip('uU'), 16) for t in re.findall(r'0[xX][0-9a-fA-F]+[uU]?', m.group(1))]
print('0x%08x' % functools.reduce(lambda a, b: a ^ b, v, 0))
```

> 历史上出过**改了 `.h` 忘了同步 `.bin`**，两个文件差一个 word 的事故。编完固件请用下面的方法核对。

---

## 三、编译

```bash
cd rowpipe_keys
bash tools/build_firmware.sh
```

产物：

| 文件 | 用途 |
|---|---|
| `software/firmware/build/soc_video_app.elf` | **烧录用这个** |
| `software/firmware/build/soc_video_app.bin` | 备用裸二进制（`load_image ... 0x1000 bin`） |

成功标志：`PASS complete application: .../soc_video_app.elf`，text 约 28 KB。

> 工具链路径在脚本里：`D:/Efinity/efinity-riscv-ide-2026.1/toolchain/bin`。
> **必须在 bash 里跑**（Git Bash / MSYS 均可），PowerShell 下会因管道问题失败。

**编完自检**（确认权重真的进固件了，而且没编错版本）：

```python
import struct, functools
blob = open('<你导出的 rowpipe_blob.bin>', 'rb').read()
d = open('software/firmware/build/soc_video_app.bin', 'rb').read()
i = d.find(blob)          # 权重按字节原样嵌在 bin 里
print('blob 在 bin 的偏移 =', hex(i) if i >= 0 else 'NOT FOUND')
```

⚠ **偏移不是固定的**（当前是 `0x34fc`，你们之前那版是 `0x3504`）——因为它前面是代码。**不要硬编码偏移，用搜索**。

---

## 四、烧录

### 4.1 完整流程

```bash
# 1) 先重配 bit（见 §5.1，这一步不能省）
cmd //c _flash_new.bat

# 2) 起 OpenOCD（后台）
"D:/Efinity/2026.1/debugger/openocd/bin/openocd.exe" \
  -f software/bsp/EfxSapphireSoc/openocd/ftdi_ti.cfg \
  -f software/bsp/EfxSapphireSoc/openocd/debug_ti.cfg &

# 3) telnet 4444 依次敲：
#    reset halt
#    load_image {<绝对路径>/software/firmware/build/soc_video_app.elf}
#    reg pc 0x1000
#    resume
```

连接 telnet 4444 的最小 Python（无第三方依赖）：

```python
import socket, time
s = socket.create_connection(('127.0.0.1', 4444), timeout=5)
s.settimeout(0.4); time.sleep(0.8)
try: s.recv(65536)
except Exception: pass
def cmd(c, t=40.0):
    s.sendall((c + '\n').encode()); buf = b''; t0 = time.time()
    while time.time() - t0 < t:
        try:
            d = s.recv(65536)
            if d:
                buf += d
                if buf.rstrip().endswith(b'>'): break
        except Exception: pass
        time.sleep(0.02)
    return buf.decode('ascii', 'replace')
cmd('reset halt', 12)
cmd('load_image {C:/.../soc_video_app.elf}', 40)
cmd('reg pc 0x1000', 4); cmd('resume', 4)
```

**成功标志**：`28156 bytes written at address 0x00001000`（数字随版本略变）。

### 4.2 用现成的 artifact（不编译）

`artifacts/` 下有历史固件，可直接烧：

```
artifacts/soc_video_app_redsky_v5.bin     ← 当前板上这个
artifacts/soc_video_app_ink_v5.bin
artifacts/soc_video_app_wave_v5.bin
```
烧法：`load_image {<路径>} 0x1000 bin`

> ⚠ **风格清单变更（2026-10-27 确认）**：
> **`scream` 已被 `redsky` 替代，不再作为并列风格存在。**
> 现存风格只有 **ink / wave / redsky** 三套。
> `artifacts/soc_video_app_scream_v5.bin` 与 `demo/reports/rowpipe/export_scream_v5/`
> 是历史遗留，**不要再拿来烧板、也不要再作为交付目标**。
> 呐喊 = redsky，说的就是同一套。

---

## 五、三个必踩的坑

### 5.1 ⚠ 重烧 ELF 会锁存采集故障（最容易浪费时间的坑）

**现象**：串口还在打，但 `MONET CAP 0 NN 0 MS 0`，`DROP` 猛涨，屏幕黑。

**原因**：反复 `load_image` 会触发采集链的锁存故障（`docs/PROJECT_HANDOFF.md` 有记载）。

**恢复**：**重配 bit**，不是 reset CPU：

```bash
taskkill //F //IM openocd.exe
cmd //c _flash_new.bat          # 用 Efinity programmer 重新配置位流
# 然后重新起 OpenOCD + 烧 ELF
```

只 `reset halt` / `resume` 是清不掉的；上电也行，但慢。

### 5.2 ⚠ XOR 不匹配 = 权重不加载

改完数组忘了改 `ROWPIPE_WEIGHT_XOR`，固件自检失败。看串口有没有权重相关的报错，或直接算一遍（§二）。

### 5.3 ⚠ `.bin` 里的权重偏移会变

不要硬编码偏移，用 §三 的 `find(blob)` 搜索。

---

## 六、验证：看串口三行

串口 **COM11，115200 8N1**（每次上电后确认端口号），每秒一行：

```
MONET CAP 17 NN 17 DISP 0 DROP 0 MS 50 ERR 0
3A state 1 exp 2547 vts 2500 mean 119 hot 146 goal 117 hold 1 R 400 B 414 AE 5 ...
DDR100M T 101178407 AR 3 DAR 3 RGAP 12 B 19
VIDEO UF 0 DUF 0 DDROP 0 FAULT 0 CSI 0 DME 0 IERR 0 AXI 0
```

| 字段 | 含义 | 期望 |
|---|---|---|
| `CAP` / `NN` | 采集 / 推理帧率 | 17-18 |
| `MS` | 每帧推理毫秒 | 50 |
| `DROP` | 风格队列丢弃 | 0 |
| `FAULT` | 采集故障 | 0（启动时可能瞬时 4，之后不涨就正常） |
| `AXI` | 总线错误 | **必须 0** |
| `B` | 等写响应占比 | ~19% |
| `RGAP` | 读气泡占比 | ~12% |
| `hot` / `goal` | 高光占比‰ / AE 目标 | hot 非 0 说明高光保护在工作 |

### 怎么看画面颜色（不用截图）

直接 dump DDR 里的风格帧算统计，比屏摄可靠得多（屏摄会被采集卡改色，见 §七）：

```python
# halt → dump_image {style.bin} 0x05800000 0x12C000 → resume
# ⚠ 风格帧在 6 个 slot 之间轮转（步长 0x140000）：0x05800000 / 0x05940000 / 0x05A80000 ...
#    0x05800000 只是 slot0。取到空数据就换下一个 slot 试；APB 没有寄存器能报当前 slot。
# 640x480x4，每像素 {B,G,R,X}，R 在最低字节，**按补码（signed int8）解释**
import numpy as np
d = np.fromfile('style.bin', dtype=np.uint8).reshape(480, 640, 4)
q = d[:, :, :3].view(np.int8).astype(np.float64)
for i, c in enumerate('RGB'):
    print('%s mean %+6.1f  sigma %5.1f' % (c, q[:, :, i].mean(), q[:, :, i].std()))
print('B-R = %+.1f   (显示值 = q + 128)' % (q[:, :, 2].mean() - q[:, :, 0].mean()))
```

> dump 速度约 **7.4 KB/s**，整帧 1.2 MB 要 ~2.8 分钟。

---

## 七、偏色的结论（你们要知道的事实）

板侧已用 DDR 直读 + 显示链逐级仿真定案：

| 环节 | B−R | 说明 |
|---|---|---|
| **DDR 里的网络输出（v5）** | **+25.6** | 你们离线预测 +21.4 —— 吻合，**你们是对的** |
| `^0x80` 之后 | +25.6 | 差分不变 |
| `luma_color_suppress`（tone） | +26.1 | 只贡献 **+0.5** |
| `lift`（公共增益，峰值 1.25×） | ≈ +31 | R/G/B 乘同一个 factor，保比例 |
| 屏摄实测 | +67.8 | 多出的 ~37 级在**采集卡**（USB 采集棒） |

⇒ **显示链清白**，偏色的主体（+21~26）是网络对该场景的固有偏色 —— 就是你们说的"DC 补偿用了训练集统计、板上是亮中性场景"。

另外板侧用 24 色卡反解过：**任何线性颜色变换都修不回右半**（对角残差 32.2、满 3×3 残差 28.4）。所以只能从权重侧解决。

---

## 八、你们要做的两件事

### 8.1 必须：按板场景重标逐通道 DC（你们提的 A2 方案）

目标：让末层输出三通道均值在**板上这个场景**下相等（现在 R −36.3 / G −30.1 / B −10.6，B 高 25.6）。

注意板侧的场景特征是：**大面积亮中性**（仪器架 + 浅色墙），左半原画 mean 136、σ 70。

建议：DC 基准用**多场景混合**（你们 §六 提的 60% 训练集 + 20% 亮中性 + 20% 暗场景），而不是只用训练集——否则换场景就会反向偏。

### 8.2 可选：+10 DC 偏置让高光到 255

现在负尾长、正侧只能到 +107，显示最高 235、高光憋着。等 8.1 修完通道失衡再加。

---

## 九、不用烧录的快速实验法（强烈建议）

调量化参数和相机增益**根本不用重烧**，直接写寄存器：

### 9.1 改 L11 量化头 / 偏置（DDR 直写）

网络每帧都从 DDR 重读权重，而 XOR 自检只在开机跑一次：

| 地址 | 内容 |
|---|---|
| `0x06F037A0 / A4 / A8` | L11 bias 三通道（int32） |
| `0x06F03860` | L11 量化头 `{qhi[21:14], qlo[13:6], shift[5:0]}` |

```
halt → mww 0x06F03860 0x001FE065 → resume
```
一次实验 **20 秒**，不是 4 分钟。

### 9.2 改相机增益（APB）

| 地址 | 内容 |
|---|---|
| `0xf8100040` | gain_r（Q8.8） |
| `0xf8100044` | gain_g |
| `0xf8100048` | gain_b |
| `0xf8100050` | 写 `1` 生效 |

这比"改固件→编译→烧→重配 bit"快 20 倍，**而且完全避开 §5.1 那个坑**。

---

## 十、成本函数（如果要动网络结构）

```
每帧算力拍 ≈ Σ_layers  (out_px_l / 16) × (ci_l × 9 + 16)
```

| 维度 | 成本 | 结论 |
|---|---|---|
| 分辨率 | **平方** | 640×480 加一层 = 11.4 ms；160×120 加一层 = 0.71 ms |
| `ci` | **线性**（×9） | |
| `cout` | **免费**（≤8 时） | MAC 阵列是 16 像素 × 8 通道全并行 |

当前帧时间 50 ms 里，**算力占 33.2 ms（66%）**，总线已经优化到不再是瓶颈。所以：
- 再提速只能靠降算力：`L10`（8→4，640×480）一层吃掉全网 **29.6%** 的 MAC 却只做上采样，降到 320×240 可省 14.4 ms
- `L0`（3→4，640×480）降到 160×120 可省 5.6 ms
- 两者合计：33.2 → 20 ms，帧时间 50 → 37 ms（17 → 27 fps）

---

## 附：文件索引

| 要看什么 | 去哪 |
|---|---|
| 量化契约（blob 格式、qlo/qhi 语义、ReLU 陷阱） | `reports/FOR_MODEL_QUANT_CONTRACT.md` |
| 本轮 v5 验收与偏色取证 | `reports/REPLY_TO_MODEL_v5_verified.md` |
| 24 色卡校准与颜色链定案 | `reports/COLOR_CHECKER_CALIB_2026-10-27.md` |
| 总线优化（为什么现在瓶颈是算力） | `reports/NETWORK_OPT_PLAN.md` |
| 逐行阅读（rowpipe 数据通路） | `reports/line_by_line/02_rowpipe_datapath.md` |
