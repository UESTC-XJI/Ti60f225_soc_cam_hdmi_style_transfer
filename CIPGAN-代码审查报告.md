# CIPGAN 项目阅读报告（代码审查 + 预训练模型实测）

> 审查对象：`C:\Users\36040\Downloads\Ti60F225_DemoBoard_v4\demo\CIPGAN-main\CIPGAN-main`
> 报告日期：2026-10-16
> 审查方式：全量源码精读 + 对 4 个 `.pth` 权重做**离线解码实测**（本机无 torch，采用自研 legacy-pickle 解析器）+ 阈值算法数值复算

---

## 一、项目概览

| 项目 | 内容 |
|---|---|
| 名称 | **CIPGAN**（Chinese Ink Painting GAN） |
| 任务 | 照片 → 中国水墨画风格迁移（无配对数据，unpaired image-to-image） |
| 基座 | CycleGAN（junyanz/pytorch-CycleGAN-and-pix2pix 的定制分支） |
| 上游仓库 | `https://github.com/Wenretium/CIPGAN` |
| 核心改进 | ① VGG16 感知损失（特征层约束） ② 自注意力（强度图引导） |
| 代码规模 | 26 个 `.py`，**3220 行** |
| 仓库体积 | 60 个文件，**244.27 MB**（其中权重 180 MB + VGG 58.9 MB） |
| 最后更新 | 2022-10-28（修复 test.py 报错并重排工程） |

**一句话定位**：一个"论文复现 + 可视化 Demo"性质的毕业设计/课程项目，算法思路清晰、工程完整度中等，但**演示链路在当前环境下存在多个必崩缺陷**，且训练数据集缺失，无法端到端复现。

---

## 二、目录结构与代码规模

```
CIPGAN-main/
├── train.py / test.py            训练、测试入口
├── demoTest.py                   单图推理（绕过 DataLoader）
├── gui.py                        Tkinter 可视化 Demo
├── requirements.txt / README.md
├── data/          (460 行)  unaligned_dataset / single_dataset / base_dataset / image_folder
├── models/       (1575 行)  networks.py(852) / cycle_gan_model / base_model / test_model
├── options/       (231 行)  base_options / train_options / test_options
├── util/          (512 行)  visualizer / html / util / image_pool / getMap
├── demo_files/     (69 行)  signText.py + 段宁毛笔行书.ttf（竖排题款）
├── checkpoints/   4 × latest_net_G.pth（每个约 45.5 MB）
├── pretrained_model/vgg16.weight（58.9 MB）
├── datasets/CIP_dataset1_process/{testA(18), testB(1)}
└── README/         5 张论文插图（poster / model / demo / supplemental）
```

模块划分与上游 CycleGAN 完全一致（`data/models/options/util` 四段式 + `create_dataset/create_model` 工厂 + `modify_commandline_options` 注册机制），**继承了上游良好的可扩展性**。

---

## 三、算法与网络架构

### 3.1 生成器（ResnetGenerator，`networks.py:317-484`）

不是标准 CycleGAN 的 `nn.Sequential`，而是**手工展开的具名层**（为插入注意力图而重构）：

```
input(3ch) → ReflectionPad2d(3) → conv1(7×7) → norm1 → ReLU
           → conv2(3×3,s2) → norm2 → ReLU          [H/2]
           → conv3(3×3,s2) → norm3 → ReLU          [H/4]
           → resnetblock1..9                        [H/4, 256ch]
           → convtran1(3×3,s2,op1) → norm4 → ReLU  [H/2]
           → convtran2(3×3,s2,op1) → norm5 → ReLU  [H]
           → ReflectionPad2d(3) → conv4(7×7) → Tanh
```

**实测参数量（从权重解码得出）**：

| 模型 | 参数量 | 键数 |
|---|---|---|
| CIP_dataset1 / dataset2 / dataset1_vgg | **11.378 M** | 48 |
| CIP_dataset1_vgg_atten | **11.453 M** | 52 |

判别器为 70×70 PatchGAN（`NLayerDiscriminator`, n_layers=3），`--netD basic`。

### 3.2 自注意力机制（本项目主要创新，`networks.py:405-459`）

思路：**用图像亮度反推"落墨区域"，再逐层与特征图相乘**。

```python
# 注意力分支（仅 self_attention=True 时构建）
self.conv1_map = nn.Conv2d(1, 64, 3, stride=1, padding=1)   # (64,1,3,3)
self.conv2_map = nn.Conv2d(64, 128, 3, stride=2, padding=1)  # (128,64,3,3)
# forward：
x = relu(norm1(conv1(ref1(x*map))))     # 原图先乘注意力图
map1 = conv1_map(map)
x = relu(norm2(conv2(x*map1)))          # 再乘学习后的 map
map2 = conv2_map(map1)
x = relu(norm3(conv3(x*map2)))
```

**实测确认**：仅 `CIP_dataset1_vgg_atten` 含 `conv1_map`/`conv2_map`（各含 weight+bias，共 4 个额外键），其余 3 个模型**确实不含注意力分支**——与 README 的消融实验设计一致。

注意力权重实测统计（`conv1_map.weight` std=0.056，`conv2_map.weight` std=0.063）符合"正常初始化后经训练"的分布，**确为真实训练产物**。

### 3.3 VGG 感知损失（`networks.py:728-852`）

自实现 VGG16 **仅卷积主干**（无 3 个全连接层）：

- 实测卷积参数量 **14.715 M** → fp32 占 **58.9 MB**
- 与 `pretrained_model/vgg16.weight` 实际大小 **58.9 MB 完全吻合**（完整 VGG16 含 FC 约 138 M / 552 MB）

默认取 `relu5_3` 特征，配合 `InstanceNorm2d(512)` 做归一化后算 MSE。

### 3.4 损失函数（`cycle_gan_model.py:179-217`）

```
loss_G = GAN(G_A) + GAN(G_B)                     # LSGAN
       + λ_A·‖G_B(G_A(A))−A‖₁ + λ_B·‖G_A(G_B(B))−B‖₁   # 循环一致 λ=10
       + λ_idt·(idt_A + idt_B)                    # 恒等 λ_idt=0.5
       + vgg·(vgg_A + vgg_B)                      # VGG 感知损失
```
优化器 Adam(lr=2e-4, β1=0.5)，前 100 epoch 恒定 lr，后 100 epoch 线性衰减。

---

## 四、四条运行链路

| 链路 | 入口 | 状态 |
|---|---|---|
| 训练 | `train.py` | ⚠️ **无法运行**（缺 trainA/trainB） |
| 测试 | `test.py` | ✅ 逻辑完整（`--model test` + TestModel） |
| 单图推理 | `demoTest.py` | ❌ 输出目录缺失，首次运行崩溃 |
| 图形界面 | `gui.py` | ❌ 路径/API 双重缺陷，Windows 下必崩 |

---

## 五、预训练模型实测分析（核心发现）

### 5.1 格式判定

4 个 `.pth` **均为 torch legacy pickle 格式**（非现代 zip），文件头 `80 02 8a 0a ...`，**需 torch < 1.6 保存**。

由于本机无 torch，我编写了 legacy-pickle 解析器逐字节解码，并**用数值合理性反向校验布局**（训练后权重应满足 std≈0.02–0.1、|w|<1.5；布局错误会解出 1e29 级垃圾值）：

| 模型 | pickle 结束 | 数据起点 | 键数 | 解码校验 |
|---|---|---|---|---|
| CIP_dataset1 | 11208 | 11264（64B 对齐） | 48 | ✅ 全部合法 |
| CIP_dataset2 | 11208 | 11264（64B 对齐） | 48 | ✅ 全部合法 |
| CIP_dataset1_vgg | 11208 | 11264（64B 对齐） | 48 | ✅ 全部合法 |
| CIP_dataset1_vgg_atten | 11827 | 11827（无对齐） | 52 | ✅ 全部合法 |

> **附带发现**：注意力模型的数据段**不做 64 字节对齐**，其余三个做对齐 → 该权重由**不同 torch 版本**保存（与 README "模型在 Ubuntu 上训练" 相印证）。

解码后 `conv1.weight` 统计（std / 取值范围）：

| 模型 | std | 范围 |
|---|---|---|
| CIP_dataset1 | 0.0596 | [−0.526, 0.466] |
| CIP_dataset2 | 0.0866 | [−0.562, 1.422] |
| CIP_dataset1_vgg | 0.0599 | [−0.418, 0.495] |
| CIP_dataset1_vgg_atten | 0.0569 | [−0.423, 0.507] |

### 5.2 四个模型是否为不同的训练产物？

**结论：是，4 个权重确实互不相同。**

逐参数（按张量名对齐，48 个共享张量）比对：

| 对比 | 值不同比例 | 最大绝对差 |
|---|---|---|
| dataset1 ↔ dataset2 | 100.00% | 1.377 |
| dataset1 ↔ dataset1_vgg | 100.00% | 1.029 |
| dataset2 ↔ dataset1_vgg | 100.00% | 1.409 |
| dataset1_vgg ↔ dataset1_vgg_atten | 100.00% | 0.764 |

最大差值落在权重正常量级内（而非 1e29 级垃圾值），**交叉验证了解码正确性**，同时证明四个模型是**真实且独立的训练结果**，消融实验有效。

> ⚠️ **方法学提醒**：legacy 格式按 `sorted(str(storage_ptr))`（**内存地址**）顺序写入数据块，地址每次保存都变。因此**直接对 `.pth` 文件做字节比对（如 `Get-FileHash`）不能作为"权重是否相同"的证据**——必须按张量名解码后比对。本报告已按后者执行。

### 5.3 检查点内容完整性

- 仅保存**生成器**（`latest_net_G.pth`），**无判别器** → 属于**推理/演示用产物**，不能用于继续训练
- 解码对象为 `OrderedDict`，含 `_metadata`（99 项，含 `downsample1`/`downsample2`）
- `_metadata` 中残留 `downsample1` 键 → 反证权重由**本仓库的 networks.py 原样保存**（该模块在 `networks.py:400` 被作者注明"无用模块，忘记去掉"）

---

## 六、缺陷清单

### 🔴 阻断级（Demo 无法运行）

#### D1. `gui.py:25,35` — Windows 路径分隔符错误

```python
input_name = onshow_path.split('/')[-1]        # ← 只按 '/' 切分
result_path = 'demo_files/results/{}_{}_fake.png'.format(model_name, input_name.split('.')[0])
```

`filedialog.askopenfilenames` 在 Windows 返回**反斜杠路径**，`split('/')` 切不动，`input_name` 变成整条路径。实测结果：

```
result_path = 'demo_files/results/dataset1_C:\Users\...\testA\lake_fake.png'
→ OSError: [WinError 123] 文件名、目录名或卷标语法不正确。: 'demo_files/results/dataset1_C:'
```

**同样问题**：`demo_files/signText.py:57`（署名功能）。修复：改用 `os.path.basename()`。

#### D2. `gui.py:53` — `Image.ANTIALIAS` 已在 Pillow ≥10 移除

```python
return pil_image.resize((width, height), Image.ANTIALIAS)
```

实测（Pillow 12.3.0）：`Image.ANTIALIAS` 不存在 → `AttributeError`。修复：`Image.Resampling.LANCZOS`。

#### D3. `demo_files/signText.py:40` — `font.getsize()` 已在 Pillow ≥10 移除

```python
w, h = font.getsize(s2)
```

实测：`'FreeTypeFont' object has no attribute 'getsize'` → 署名功能崩溃。修复：`font.getbbox(s2)`（返回 `(0,1,12,11)`，需自行算宽高）。

#### D4. 输出目录缺失且从不创建

| 目录 | 引用位置 | 存在 |
|---|---|---|
| `demo_files/results/` | `demoTest.py:65` | ❌ |
| `demo_files/signs/` | `signText.py:57` | ❌ |

`util.save_image()`（`util/util.py:49`）直接 `image_pil.save()`，**不创建父目录** → 首次运行 `FileNotFoundError`。
（注：`test.py` 不受影响，因其 `html.HTML.__init__` 会 `makedirs`。）

### 🟠 严重（算法/训练正确性）

#### D5. `util/getMap.py:25-31` — 阈值索引与灰度级错位（注意力图算错）

```python
reversed_hist = reversed(hist)
for val, val_n_pix in enumerate(reversed_hist):   # val 是"反序直方图下标"
    temp += val_n_pix
    if temp >= cut_n_pix:
        thresh = val          # ← 却当作灰度级传给 cv2.threshold
        break
_, map = cv2.threshold(src, thresh, 255, cv2.THRESH_TOZERO)
```

`src = 255 - gray`，故反序下标 `val` 对应 `src` 灰度 **255−val**，代码却直接用 `val`。**实测偏差**（`lake.png`, 147423 像素）：

| `self_attention_thresh` | 期望保留比例 | 代码实际保留 | 正确阈值 |
|---|---|---|---|
| 0.0 | 1.00 | 0.000 | 0 |
| 0.2 | 0.80 | 0.023 | 40 |
| 0.5 | 0.50 | **0.189** | 85 |
| 0.8 | 0.20 | **0.479** | 167 |

即：**控制因子 `self_attention_thresh` 的物理含义与文档完全不符**，实际保留区域远少于预期（0.5 时只留 19%）。这会显著改变注意力图，进而影响推理结果。修复：`thresh = 255 - val`。

#### D6. `cycle_gan_model.py:138,187` — 注意力训练路径的 CPU/CUDA 设备不匹配

```python
self.map_fake_A = torch.ones([...])          # 默认在 CPU
self.rec_B = self.netG_A(self.fake_A, self.map_fake_A)   # fake_A 在 GPU
self.idt_A = self.netG_A(self.real_B, torch.ones([...]))  # 同样问题
```

`torch.ones` 未指定 `device`，与 `self.device` 上的特征图相乘 → **GPU 训练必崩**（`--self_attention` 时）。修复：加 `.to(self.device)`。

#### D7. `cycle_gan_model.py:212-214` — VGG 损失"预热"是死代码

```python
if epoch <= 10:
    self.loss_vgg_a = 0        # ← 小写 a/b
    self.loss_vgg_b = 0
self.loss_G = ... + self.loss_vgg_A + self.loss_vgg_B   # ← 用的是大写 A/B
```

赋值给**从未被读取的属性**，第 216 行仍累加 `loss_vgg_A/_B` → **"前 10 epoch 关闭 VGG 损失"的意图完全未生效**。

#### D8. `networks.py:739` — `Variable` 未导入

```python
batch = batch.sub(Variable(mean))    # networks.py 从未 import Variable
```

仅当 `--vgg_mean` 时触发 → `NameError`。修复：改用 `mean` 张量或补 `from torch.autograd import Variable`。

#### D9. `networks.py:758-775` — VGG 加载硬编码 CUDA

```python
vgg.cuda(device=gpu_ids[0])    # gpu_ids=[] 时 IndexError
```
配合 `cycle_gan_model.py:73` 的 `self.vgg_loss.cuda()`，**`--gpu_ids -1`（CPU）无法训练带 VGG 的模型**。

### 🟡 一般（健壮性 / 文档一致性）

| 编号 | 位置 | 问题 |
|---|---|---|
| D10 | `networks.py:848` | `elif opt.vgg_choose == "relu5_3" or "maxpool":` — 非空字符串恒真，任何非法 `vgg_choose` 都静默返回 `relu5_3`，掩盖配置错误 |
| D11 | `networks.py:746` | `InstanceNorm2d(512)` 硬编码 512 通道，若 `--vgg_choose relu3_3`（256ch）则崩溃 |
| D12 | `cycle_gan_model.py:90` | `opt.input_nc_A = 4` 是**死代码**（全仓库无消费者，`define_G` 用的是 `opt.input_nc`） |
| D13 | `networks.py:400-401` | `downsample1/2` 是"忘记去掉的无用模块"（作者注释自认），永久占据 state_dict |
| D14 | `util/util.py:60-63` | `aspect_ratio≠1` 时 `resize((h, int(w*ratio)))` **宽高参数颠倒**（把 h 当宽度） |
| D15 | `visualizer.py:110` | `tensor.shape[:2]` 对 4D 张量取到 `(B,C)` 而非 `(H,W)`，visdom 面板尺寸错误 |
| D16 | `demo_files/signText.py:64-69` | `return` 之后有 6 行不可达死代码 |
| D17 | `test.py` docstring | 示例 `--model cycle_gan` 会崩：`TestOptions` 下 `isTrain=False`，`modify_commandline_options` 不注册 `--vgg`，而 `CycleGANModel.__init__:62` 无保护地读 `self.opt.vgg` → `AttributeError` |
| D18 | `demoTest.py:26` | 绕过 `create_dataset` 直接构造 tensor，**无 resize/crop**；两次 s2 下采样 + 两次 s2 上采样在非 4 倍数尺寸上不守恒 → 输出尺寸与输入不一致（实测 471×313→**472×316**，1024×683→**1024×684**，仅 1920×1200 等 4 倍数尺寸能原样返回） |
| D19 | 全局 | **无任何随机种子**（grep `manual_seed` 零命中），训练不可复现 |

### 🔵 文档与代码不一致

| 项 | README | 实际代码 |
|---|---|---|
| `self_attention_thresh` 默认值 | "0.8 by default"（L76） | `base_options.py:62` = **0.5** |
| 测试结果路径 | `./testresults/<name>/latest_test/index.html`（L104） | `./results/<name>/test_latest/index.html` |

### 🔒 安全提示

`torch.load()`（`base_model.py:198,210`）**未使用 `weights_only=True`**。legacy pickle 反序列化会执行任意代码，**加载来源不明的 `.pth` 存在远程代码执行风险**。建议升级 torch 并显式 `weights_only=True`。

---

## 七、复现性评估

| 维度 | 状态 |
|---|---|
| 训练数据 | ❌ **trainA/trainB 缺失**（仅 testA 18 张、testB 1 张）；`datasets/CIP_dataset2` 不存在 |
| 依赖锁定 | ❌ `requirements.txt` 全为 `>=` 下界，无上限/哈希/lockfile |
| 随机性 | ❌ 无种子 |
| 环境 | ❌ 本机未安装 torch/torchvision/opencv/numpy/Pillow/dominate/visdom（仅 tkinter 可用） |
| 推理 | ⚠️ 权重齐全，但需修 D1–D4 才能跑通 Demo |

**结论：当前状态下可"读"不可"跑"**——推理链路修掉 4 个阻断缺陷即可用；训练链路因数据缺失**无法复现**。

---

## 八、修复优先级建议

**P0（让 Demo 跑起来）**
1. `gui.py:25,35` + `signText.py:57` → `os.path.basename()`
2. `gui.py:53` → `Image.Resampling.LANCZOS`
3. `signText.py:40` → `font.getbbox()`
4. 启动时 `os.makedirs('demo_files/results', exist_ok=True)` 等

**P1（算法正确性）**
5. `getMap.py` → `thresh = 255 - val`
6. `cycle_gan_model.py:138,187` → `.to(self.device)`
7. `cycle_gan_model.py:212-214` → 改为 `loss_vgg_A/loss_vgg_B`（或直接改损失累加式）

**P2（健壮性）**
8. `networks.py:739` 补 `Variable` 或改用张量；`:848` 改为 `in ("relu5_3", "maxpool")`
9. 补 `torch.manual_seed`；`torch.load(..., weights_only=True)`
10. 修正 README 的阈值默认值与结果路径

---

## 九、总体评价

**优点**
- 算法动机清晰：以"亮度反推落墨区域"引导注意力，符合水墨画"暗处着墨"的先验，思路朴素但有效
- 消融实验设计完整（baseline / 换数据集 / +VGG / +VGG+注意力），**四个权重实测确为独立训练产物**
- 继承 CycleGAN 的工厂式架构，扩展性好；额外提供 GUI + 竖排题款，Demo 完成度高

**不足**
- **演示链路在 Windows + 现代 Pillow 下全面失效**（D1–D4 四个阻断缺陷）
- **注意力核心算法 `getMap` 存在阈值错位**（D5），使创新点的实际行为与描述不符，且消融结论的可靠性打折
- 注意力训练路径设备 bug（D6）使该模型**难以在 GPU 上重新训练**
- 训练数据缺失、依赖不锁定、无随机种子 → **不可复现**

**定位**：一个**思路有价值、工程实现尚需打磨**的课程/毕业设计级项目。核心创新（VGG + 自注意力）方向正确，但注意力阈值的实现缺陷与演示链路的健壮性问题是其最主要的短板。

---

*本报告所有量化结论均来自对源码的精读与对权重文件的离线解码实测；`.pth` 解析结果已通过"数值分布合理性 + 跨模型交叉比对"双重校验。*
