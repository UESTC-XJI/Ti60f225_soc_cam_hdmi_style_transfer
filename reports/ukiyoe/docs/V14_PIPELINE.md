# v14 完整流水线记录（笔触 + 暖调）

> 日期：2026-10-15
> 从「增加笔触」到「可烧录产物」的全过程，含 4 个发现/修复的真实缺陷

---

## 一、产出

| 产物 | 大小 | SHA256（前 16） |
|---|---|---|
| `reports/ukiyoe/student_v14/step_008000.pt` | 201,083 B | `B1709CBC6FB66F54` |
| `reports/ukiyoe/export_v14/coeff.bin` | 24,576 B | `C86B056D71E92749` |
| `rtl/style/model/coeff.hex` | 49,664 B | `B2DEE04D7A94D09B` |
| `software/firmware/style_weights.h` | 76,953 B | `AB09930BD4A1E3E4` |
| `software/firmware/style_selftest.h` | 19,392 B | `8EC45470511F14A6` |
| **`reports/ukiyoe/firmware/soc_video_app_v14.bin`** | 44,624 B | **`47E0E0FFBE573D54`** |
| **`outflow_v14/ti60f225_oob.bit`** | 3,220,653 B | **`581C441D64B8FA21`** |

---

## 二、笔触：核心成果

构造了一个**可微的笔触（方向性伸长）统计量**：

```python
m = sigmoid((80 - L*255) / 8)              # 软暗部掩码
eH = -max_pool2d(-m, (1,k))                # 水平连续暗区
eV = -max_pool2d(-m, (k,1))                # 垂直连续暗区
elongation = sum(eH) / sum(eV)             # >1 = 水平伸长
```

**对旋转鲁棒**（照片在 0/90/180/270 度均为 1.002，画作 1.102），
**且随核增大而增长**（画作 k=5→21 为 1.07→2.05，照片恒为 ~1.0）——
这是长笔触的特征，不是内容朝向造成的。

| 样本 | 伸长率 |
|---|---|
| 输入照片 | 1.025 |
| official | 1.037 |
| v9 / v10 | 1.033 / 1.075 |
| **真实浮世绘（20 张）** | **1.138** ← 目标 |
| v11（weight 60） | 1.625 |
| v12（weight 15） | 1.577 |
| **v13/v14（双侧损失）** | **1.100 / 1.082** |

---

## 三、修复的 4 个真实缺陷

### 缺陷 1：`cast` 广播错误（该项一直完全失效）

```python
# 错：y_mean 是 (B,3)，cast 建成 (1,3,1,1)
cast = ...view(1, 3, 1, 1)
mean_target = base + cast        # -> (1,3,B,3)

# 对：形状必须匹配 (B,3)
cast = torch.tensor([...])       # (3,)
assert cast.shape == (3,)
```

**后果**：目标被广播成 `(1,3,B,3)`，`F.mse_loss` 对 3 个通道副本求平均。
而 cast 三个值之和为 0 → **该项退化为普通 tone 损失，暖调约束完全没起作用。**

**证据**：v13（bug 生效）R-B **+7.5**；v14（修复后）R-B **+19.5**（官方 +21.2）。

### 缺陷 2：`cast` 数值偏小

| | R-B 贡献 |
|---|---|
| 旧 `0.0289,-0.0089,-0.0200` | +0.0489 |
| **实测官方 R-B 增量** | **+0.0655** |
| 新 `0.0294,0.0067,-0.0361` | +0.0655 ✅ |

推导：官方三通道偏移 R +0.2035 / G +0.1808 / B +0.1380，
减去其均值 0.1741 → cast 三者之和为 0（不动亮度），只改色相。

### 缺陷 3：笔触损失是**单侧**的（这解释了过冲）

```python
# 错：ratio 超过 target 后损失恒为 0，没有力把它拉回来
stroke = F.relu(target - ratio)
# 对：双侧平方，把工作点固定在目标
stroke = (ratio - target) ** 2
```

**这解释了为什么 v11（weight 60）达到 2.074、v12（weight 15）仍达 2.031**
—— 权重几乎不起作用，因为超过目标后梯度就是 0。

### 缺陷 4：目标值聚合方式不一致（与 Gram 错误同类）

损失对 **batch 池化**，而 1.378 是**逐图平均**：

| | 池化（损失看到的） | 逐图平均 |
|---|---|---|
| 真实浮世绘 | **1.138** | 1.378 |

**改 1.138 后 v13 落在 1.100** —— 不再过冲。

---

## 四、部署验证（全部通过）

| 阶段 | 结果 |
|---|---|
| 导出 | 23 层、payload 11,056 B、**层结构与 v3 完全相同**（仅系数变） |
| **整数 oracle vs FP32** | **MAE 2.309 / PSNR 40.86 dB**（v3：2.530 / 40.07）→ **新模型更好** |
| 确定性 | 同一输入两次运行结果完全相同 |
| RTL 仿真（新系数） | **PASS** rows=192 pixels=2976，`style_row_tb` 全图精确复现 |
| 综合 | map / interface / pnr / pgm **全部 PASS**，min slack **+0.023 ns** |
| 资源 | style_demo 26,537 XLR / 140 mem / 121 dsp（v3：26,564 / 140 / 121） |

**关于「整数 oracle vs QAT」的更正**：我在 `_export_v14.py` 里把
「oracle 与 QAT 须逐位一致」当验收标准，实测 max diff 15 判为失败。
**这个标准本身是错的** —— QAT 是伪量化（每层独立 scale + STE），
oracle 是精确 int32 + M16/B32/shift 仿射，两者都是同一 int8 网络的近似。
正确的板级保真指标是 **oracle vs FP32**（上表）。

---

## 五、固件部署的 2 个关键发现

### 发现 1：板上权重来自**固件**，不是比特流

`style_driver.c:37-39` 在启动时无条件把全部 6144 个系数写入 RTL：

```c
for(row=0..255) for(word=0..23) {
    regs[10] = (row<<8)|word;
    regs[11] = style_coefficients[row*24+word];   // 来自 style_weights.h
}
```

**所以只换比特流不够 —— 必须同时更新固件。**

### 发现 2：自检失败会让板子**死循环**

`main.c:53-56`：

```c
if(style_rc) {
    uart_writeStr(...,"STYLE weights/IRQ/RGB self-test FAIL; ...");
    for(;;) {}          // 永久挂起
}
```

**因此系数与期望值必须来自同一模型**，否则烧录后板子直接卡住。

### 固件内嵌数组的精确布局（已逐词验证）

| 数组 | 偏移 | 词数 | 验证 |
|---|---|---|---|
| `style_test_expected[768]` | `0x354C` | 768 | 768/768 ✓ |
| `style_test_input[768]` | `0x414C` | 768 | 768/768 ✓ |
| `style_coefficients[6144]` | `0x4D4C` | 6144 | 6144/6144 ✓ |

**验证方法**：`soc_video_app_monet_baseline.bin` 与 git HEAD 头文件逐词比对，
三数组全部 100% 匹配；且两个已有 bin 的差异**只落在系数区**，
证明没有其他数据在两次构建间移动。

### 无工具链的解决方案：字节补丁

RISC-V 工具链（`C:/Efinity/efinity-riscv-ide-2026.1/toolchain/bin`）**未安装**。
但由于三个数组长度不变，可直接字节补丁：

```python
data[0x354C : 0x354C+3072] = expected  # 768 词小端
data[0x414C : 0x414C+3072] = input
data[0x4D4C : 0x4D4C+24576] = coeff    # 6144 词小端
```

**结果**：三数组重读 768/768 / 768/768 / 6144/6144，
**目标区外改动字节数 = 0**。

### 顺带发现并修复：头文件集合不一致

`prepare_style_firmware.py` 在 20:43 运行，当时 `rtl/style/model/style_weights.h`
还是 v3；`program.py` 在 20:57 才更新为 v14。导致：

- `firmware/style_weights.h` = **v3** 系数
- `firmware/style_selftest.h` = **v14** 期望值

**这个组合烧进去，自检必然失败 → `main.c:56` 死循环。**
已重跑生成器（`STYLE_ORACLE_DIR=reports/ukiyoe/export_v14`）修复。

---

## 六、系数序列化格式（已全部核实一致）

| 文件 | 格式 | 与 `style_weights.h` 的一致性 |
|---|---|---|
| `style_weights.h` | 6144 词，`row*24+word` | — |
| `coeff.bin` | 每地址 96 字节小端（256 地址） | **6144/6144** ✓ |
| `coeff.hex` | 256 行 × 192 hex 字符 | **6144/6144**（反向读取）✓ |

**注意 Verilog 片选方向**：`initial_coeff[a][bank*32 +: 32]`
→ **bank0 是最低 32 位 = 行末 8 个字符**（不是行首）。
我最初按行首解析得到 43.9%，按正确语义反向后为 100%。

---

## 七、烧录步骤（硬件连接后执行）

```powershell
# 1. 烧录比特流 + 固件
D:\Efinity\2026.1\pgm\bin\efx_pgm\ftdi_program.py `
  --bit outflow_v14\ti60f225_oob.bit `
  --bin reports\ukiyoe\firmware\soc_video_app_v14.bin

# 2. 串口监视（COM 口按实际调整）
# 期望启动输出：
#   SOC VIDEO boot
#   DDR scratch PASS
#   STYLE INT8 RGB self-test PASS; MONET VGA
```

**若出现 `self-test FAIL` 后无输出 → 说明系数/期望值不匹配，勿重复烧录。**

---

## 八、仍未做

| 项 | 说明 |
|---|---|
| 上板实测 | 无硬件连接与串口，未执行 |
| 夜景文字伪影 | v14 的高对比边缘仍有拖影（见 `v14_night_zoom.png`）；official 夜景本身更暗（very-dark 31.4% vs v14 6.1%），需上板确认观感 |
| 我先前一个被自己推翻的假设 | 「grain 损失可被低频块满足产生黑斑」—— 实测低频块 highpass 仅 0.003–0.007（目标 0.0484），**该假设不成立** |
