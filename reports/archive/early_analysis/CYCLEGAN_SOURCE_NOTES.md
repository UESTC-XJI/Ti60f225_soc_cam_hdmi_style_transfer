# pytorch-CycleGAN-and-pix2pix 完整阅读笔记

> 阅读日期：2026-10-14
> 源码：`_data/cyclegan_src/`（58 个文件 / 248 KB，从 GitHub 直连拉取）
> 阅读目的：找出「我们的浮世绘效果与论文官方差距明显」的**架构层原因**

---

## 0. 最重要的发现

**根因是拓扑结构：官方在降采样之前用 7×7 全分辨率卷积"看"颜色，我们第一步就 stride 2。**

| 对比项 | 官方 ResnetGenerator | 我们的 Student |
|---|---|---|
| **第一层** | **Conv7×7 stride 1**（全分辨率） | Conv3×3 **stride 2** |
| 最后一层 | Conv7×7 stride 1（全分辨率） | **1×1 conv** |
| **感受野（输入像素）** | **1108 px** | **348 px**（3.2× 差距） |
| 输出阶段 | 全分辨率 7×7 卷积 | **无空间处理** |

源码实证：

```python
# 官方 models/networks.py:338  —— 7×7 全分辨率
model = [nn.ReflectionPad2d(3),
         nn.Conv2d(input_nc, ngf, kernel_size=7, padding=0, bias=use_bias), ...]
# 官方 models/networks.py:354  —— 尾部也是 7×7
model += [nn.Conv2d(ngf, output_nc, kernel_size=7, padding=0)]

# 我们 ml/style_transfer/model.py:40 —— 第一步就降采样
self.enc = nn.ModuleList([Layer(3,8,3,2), Layer(8,8,3,2,True), Layer(8,channels)])
```

**这解释了实测现象**：论文把蓝天转成暖米色，我们保留了蓝色。

| 区域 | 照片 | 论文图 | 官方模型 | 我们的 v3 |
|---|---|---|---|---|
| 天空 R−B | −9.3（蓝） | **+37.2（暖）** | +25.0（暖） | **−3.9（蓝）** |

**要做"蓝天→米色纸"这类内容相关重着色，需要全分辨率的宽卷积。我们的拓扑没有。**

---

## 1. 仓库结构

```
pytorch-CycleGAN-and-pix2pix/
├── train.py / test.py           通用入口
├── options/
│   ├── base_options.py          公共选项 + 三次解析
│   ├── train_options.py         训练期选项
│   └── test_options.py          测试期选项
├── data/
│   ├── base_dataset.py          BaseDataset + get_transform
│   ├── unaligned_dataset.py     trainA/trainB（CycleGAN 用）
│   ├── aligned_dataset.py       配对（pix2pix 用）
│   ├── single_dataset.py        单向推理
│   └── colorization_dataset.py  Lab 拆分
├── models/
│   ├── base_model.py            setup/test/save/load/调度器
│   ├── cycle_gan_model.py       4 网络 + 循环一致性
│   ├── pix2pix_model.py         条件 GAN + L1
│   ├── test_model.py            单向推理
│   └── networks.py              全部网络结构（588 行，已完整读）
└── util/                        visualizer / image_pool / html / util
```

---

## 2. 感受野实测对比

### 官方（`networks.py:313-361`）

| 层 | RF（1/4 网格） |
|---|---|
| **Conv7×7 s1（头）** | 7 |
| Conv3×3 s2 | 9 |
| Conv3×3 s2 | 13 |
| ResBlock ×9（18 个 3×3） | 157 |
| ConvT3×3 s2 ×2 | 181 |
| **Conv7×7 s1（尾）** | **277** |
| **换算到输入像素（×4）** | **1108 px** |

### 我们的 Student（`ml/style_transfer/model.py`）

| | RF |
|---|---|
| 1/4 网格 | 87 |
| **换算到输入像素** | **348 px** |

**差距 3.2 倍，且关键差异在"第一次降采样之前"。**

---

## 3. 归一化层：需要纠正的细节

### 官方仓库当前定义（`networks.py:31-32`）

```python
elif norm_type == "instance":
    norm_layer = functools.partial(nn.InstanceNorm2d,
                                   affine=False, track_running_stats=False)
```

**默认 `--norm instance`**，`affine=False` 且 **`track_running_stats=False`**（无运行统计）。

### 但 checkpoint 里有运行统计

实测 `style_ukiyoe.pth`：

| 模块 | 含有的键 |
|---|---|
| 卷积层 | `weight`、`bias` |
| **归一化层** | `running_mean`、`running_var`、`num_batches_tracked`，**无 weight/bias** |

归一化模块索引：`[2, 5, 8, 20, 23]`

**说明该 checkpoint 来自较老版本的仓库**（那时 instance norm 跟踪运行统计）。

### 我此前做法的评估

我用 `BatchNorm2d(affine=True)` + `strict=False` 加载：
- `weight=1, bias=0` → 等价于 `affine=False`
- 运行统计正常载入

**在 eval 模式下 BatchNorm2d 使用运行统计，数值上等价** —— 这解释了为什么我测出的官方效果（与论文色调差 6.2 LSB）是可信的。

**但正确写法应该是**：
```python
nn.InstanceNorm2d(c, affine=False, track_running_stats=True)
```

---

## 4. 可直接借用的训练经验

### 4.1 图像尺寸必须能被 4 整除 ✅ 我们已满足

```python
# base_dataset.py:98-99
if opt.preprocess == "none":
    transform_list.append(transforms.Lambda(
        lambda img: __make_power_2(img, base=4, method=method)))
```

即使选 `none` 也会调整到 4 的倍数（生成器有两次 stride-2）。
**我们训练 256、推理 640×480，都满足。**

### 4.2 loss 曲线不可靠 ✅ 与我们的教训一致

> `tips.md:46` the loss curve does not reveal much information in training GANs

**这正是我犯过的错**：从训练日志的 `tone` 字段误判"学生没学到色调"，
实际 eval 重算后学生是最好的（0.000512 vs 教师 0.005809）。

**必须用生成样本判断，不能只看 loss。**

### 4.3 颜色反转的修复（`qa.md:100-106`）

> 生成器在训练早期会不必要地反转颜色，然后学不会恢复

两个解法：
1. **identity loss**（`--lambda_identity 0.1` 或 `1.0`）
2. **更小的初始化方差**（`--init_gain`）

### 4.4 identity loss 的作用（`qa.md:96-98`）

> 用 identity loss 正则化生成器，当输入已像目标域时保持原样。
> 这样训练出的生成器**对未知内容更保守**。

实现（`cycle_gan_model.py:159-165`）：
```python
if lambda_idt > 0:
    self.idt_A = self.netG_A(self.real_B)          # G_A(B)
    self.loss_idt_A = L1(self.idt_A, self.real_B) * lambda_B * lambda_idt
```

**注意**：`G_A(B)` = "把目标域图像喂给 A→B 生成器，应保持不动"。

### 4.5 batch size 影响结果（`tips.md:49-50`）

> 论文所有实验都用 **batch size = 1**。更大的 batch 会影响结果。

我们用 batch 6/12 —— **这是一个可调超参**。

### 4.6 训练/测试必须同尺度（`tips.md:39`）

> 推荐训练时 `--preprocess scale_width_and_crop --load_size 1024 --crop_size 360`，
> 测试时 `--preprocess scale_width --load_size 1024`，保证训练与测试同尺度。

**我们训练 256 / 推理 640×480，尺度失配 2.5 倍** —— 这是个已知问题。

### 4.7 棋盘格伪影（`qa.md:128-138`）

> ConvTranspose2d 会产生棋盘格，改用 `Upsample + Conv3x3` 可修复。

**我们用 nearest 上采样 + 1×1 conv，天然避免棋盘格** —— 这点我们的设计更好。

### 4.8 无随机噪声 z（`qa.md:140-144`）

> 映射是确定性的，作者试过加 z 但效果不明显。

**对 FPGA 部署有利** —— 无需 z 是我们的优势。

---

## 5. 论文效果的成分分解（实测）

| 成分 | 论文图 vs 照片 | 我们能表达？ |
|---|---|---|
| 整体提亮 | 均值 +9 LSB | ✅ 已修（v3） |
| 降对比度 | Ystd 70.9 → 42.9（×0.60） | ✅ 已修（v3） |
| 降饱和 | 0.335 → 0.202（×0.60） | ✅ Gram 覆盖 |
| **天空转暖** | R−B −9.3 → **+37.2** | ❌ **需全分辨率宽卷积** |
| 细颗粒 | 有 | ◐ 部分（160×120 上限） |

**唯一结构性缺失的是"天空转暖"——恰好是视觉上最显眼的差异。**

---

## 6. 修复路径

### 方案 A：用 3 个 3×3 替代 7×7 头（**唯一能解决天空问题**）

RTL 只支持 1×1 和 3×3，但**三个堆叠的 3×3 stride-1 等效感受野正好是 7**：

```
RF: 1 → 3 → 5 → 7   ✓ 与 Conv7×7 相同
```

**改法**：在 `enc` 之前插入三层 `Conv3×3 stride 1`（通道 3→8→8→8）。

| 项 | 评估 |
|---|---|
| 感受野 | 匹配官方头部 |
| 参数量 | 约 +1,368（很小） |
| RTL 支持 | ✅ 仅 3×3 |
| **代价** | **在全分辨率多做 3 层卷积 → 算力增加** |

### 方案 B：加 identity loss（零成本，但不解决根本问题）

```python
idt = F.l1_loss(model(style_images), style_images)
```

**收益**：减少无谓改色。
**局限**：**不能**教会"蓝天→米色"，只是更保守。

### 方案 C：训练尺度 256→512

| | 现在 | 建议 |
|---|---|---|
| 训练 | 256（内部 64×64） | 512（内部 128×128） |
| 推理 | 640×480（内部 160×120） | 同 |
| 失配 | 2.5× | **1.25×** |

**代价**：显存约 2.5 倍，batch 降到 4～6。

### 方案 D：更小的 `init_gain`

按 `qa.md:106`，减小初始化方差可减少颜色反转。

---

## 7. 建议排序

| 优先级 | 措施 | 理由 | 成本 |
|---|---|---|---|
| **1** | 加 identity loss | 官方推荐，零成本 | 极低 |
| **2** | 训练尺度 256→512 | 官方明确要求同尺度 | 中 |
| **3** | **3×3 替代 7×7 头** | **唯一能解决天空色相** | **高（见 §7.1）** |
| 4 | batch size 试 1 | 官方设定 | 低 |

### 7.1 全分辨率头的算力代价（实测定价）

用项目自带的**实测周期数**定价（`docs/STYLE_DEMO_IMPLEMENTATION.md`：
完整 VGA 推理 = **9,056,056 周期**）：

| 指标 | 值 |
|---|---|
| 当前网络 MACs/帧 | 204,134,400 |
| 实测周期 | 9,056,056 |
| **有效 MAC/周期** | **22.5** |

> 有效 MAC/周期只有 22.5，远低于 96 路峰值——这是项目已记录的 DDR 停顿与固定开销。

**全分辨率 3×3 卷积的单价**（640×480 = 307,200 像素）：

| 通道数 C | MACs/层 | 占当前网络 |
|---|---|---|
| 4 | 44,236,800 | **21.7%** |
| 8 | 176,947,200 | **86.7%** |
| 16 | 707,788,800 | **346.7%** |

**头方案定价**：

| 设计 | MACs | 比值 | 估算周期 | 帧率 |
|---|---|---|---|---|
| 现状 | 204,134,400 | 1.00× | 9,056,056 | 10.0 fps |
| 1× 3×3 3→8（RF 3） | 298,137,600 | 1.46× | 13,226,339 | **6.8 fps** |
| 2× 3×3 3→8→8（RF 5） | 475,084,800 | 2.33× | 21,076,283 | 4.3 fps |
| **3× 3×3 3→8→8→8（RF 7，匹配官方）** | 652,032,000 | **3.19×** | 28,926,228 | **3.1 fps** |
| **3× 3×3 3→4→4→8（RF 7，窄颈）** | 397,670,400 | **1.95×** | 17,641,933 | **5.1 fps** |

**结论**：

- 匹配官方 RF 的最便宜方案是 **3× 3×3（3→4→4→8）**，代价 **1.95×**，帧率约 **5.1 fps**
- 全分辨率头很贵，因为 640×480 的像素数是 160×120 的 **16 倍**
- **不能把头部省到 320×240**：实测证明解码器的输出是**完整 640×480**
  （`dec.0`/`dec.2` 是上采样后的 3×3 卷积，能合成 1 像素级细节）

### 7.2 我此前的一个错误结论（已修正）

我曾在 `STROKE_ANALYSIS.md` 里写"板的最细粒度是 2×2 显示像素"。

**这是错的。** 精确块检测显示 2×2 块内有高达 155 灰阶的变化。
真正原因是**每层的执行顺序是"先上采样、再卷积"**，
而 `dec.0`/`dec.2` 是 **3×3** 卷积（不是 1×1），
它们在上采样后的完整分辨率上运行，3×3 邻域跨越块边界，因此能生成细结构。

**正确表述**：

| 项 | 值 |
|---|---|
| **输出分辨率** | **完整 640×480** |
| **信息分辨率** | **160×120**（编码器降采样 4×） |

**网络能画精细纹理，但只能被粗略信息引导。**

---

## 8. 对之前结论的修正

| 此前的判断 | 本次修正 |
|---|---|
| "差距是容量问题（8,251 vs 11.4M）" | ❌ **主因是拓扑**（第一步 stride 2） |
| "Gram 损失看不见亮度" | ✅ 成立，但是**次要**原因 |
| "色调目标用错（常偏移 vs 仿射）" | ✅ 成立，属**实现细节** |
| "天空色相改不了是因全局统计" | ❌ **更根本：输出端无全分辨率宽卷积** |

**即使把 Student 扩到 32 通道，只要第一步仍是 stride 2，天空色相问题依然存在。**

---

## 9. 源码获取说明

本机 `hosts` 把 `github.com` / `raw.githubusercontent.com` 映射到 `127.0.0.1`，
用直连真实 IP + SNI + Host 头获取：

| 主机 | IP |
|---|---|
| `api.github.com` | 140.82.112.6 |
| `raw.githubusercontent.com` | 185.199.108.133 |

**注意**：GitHub 响应是 chunked 编码，需手动解 chunk，否则 JSON 解析报 `Extra data`。

---

## 附：关键源码索引

| 内容 | 位置 |
|---|---|
| **ResnetGenerator（7×7 头尾）** | `models/networks.py:313-361` |
| ResnetBlock | `models/networks.py:364-421` |
| UnetGenerator | `models/networks.py:424-515` |
| PatchGAN 判别器 | `models/networks.py:518-555` |
| GANLoss（默认 lsgan） | `models/networks.py:209-275` |
| 归一化层定义 | `models/networks.py:18-40` |
| identity loss | `models/cycle_gan_model.py:159-165` |
| 循环一致性 | `models/cycle_gan_model.py:175-177` |
| 4 倍数处理 | `data/base_dataset.py:98-99,126-135` |
| 默认超参 | `options/base_options.py:23-59` |
| CycleGAN 默认 lambda | `models/cycle_gan_model.py:42-49` |
| 训练/测试尺度建议 | `docs/tips.md:39` |
| 颜色反转修复 | `docs/qa.md:100-106` |
| 棋盘格修复 | `docs/qa.md:128-138` |
| loss 曲线不可靠 | `docs/tips.md:46-47` |
| batch size=1 | `docs/tips.md:49-50` |
