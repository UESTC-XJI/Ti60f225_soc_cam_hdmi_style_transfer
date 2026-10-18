# pytorch-CycleGAN-and-pix2pix 阅读笔记

> 仓库地址：<https://github.com/junyanz/pytorch-CycleGAN-and-pix2pix>
> 阅读日期：2026-10-13
> 阅读材料：README、`docs/overview.md`、`docs/tips.md`、`docs/qa.md`，以及 `train.py`、`test.py`、`models/{base,cycle_gan,pix2pix}_model.py`、`models/networks.py`、`data/{__init__,base_dataset,aligned_dataset}.py`、`options/base_options.py` 源码。
> 取数说明：本机对 `github.com` / `raw.githubusercontent.com` 的域名解析被拦截（返回非公网 IP），实际源码经 GitLab 镜像 <https://gitlab.cs.fau.de/yf84ykyq/pix2pix> 读取。文中所有结论均可回溯到源码。

---

## 目录

- [1. 一句话定位](#1-一句话定位)
- [2. 两篇论文与两种任务](#2-两篇论文与两种任务)
- [3. 仓库目录结构](#3-仓库目录结构)
- [4. 四个关键设计模式](#4-四个关键设计模式)
- [5. 数据流：从命令行到一次迭代](#5-数据流从命令行到一次迭代)
- [6. 数据加载层（data/）](#6-数据加载层data)
- [7. 模型层（models/）](#7-模型层models)
- [8. 网络结构（networks.py）](#8-网络结构networkspy)
- [9. 损失函数逐项推导](#9-损失函数逐项推导)
- [10. 训练/测试循环](#10-训练测试循环)
- [11. 命令行选项体系](#11-命令行选项体系)
- [12. 上手命令速查](#12-上手命令速查)
- [13. 高频踩坑（docs/qa.md 精华）](#13-高频踩坑docsqamd-精华)
- [14. 如何扩展：自定义模型与数据集](#14-如何扩展自定义模型与数据集)
- [15. 阅读后的评价与适用边界](#15-阅读后的评价与适用边界)

---

## 1. 一句话定位

这是 **CycleGAN**（无配对图像翻译，ICCV 2017）与 **pix2pix**（成对图像翻译，CVPR 2017）的官方 PyTorch 实现，作者 Jun-Yan Zhu、Taesung Park、Tongzhou Wang。

它不是一个「跑一个模型」的脚本仓库，而是一套**可插拔的通用 image-to-image 训练框架**：

- 换算法 → 换 `--model`
- 换数据组织方式 → 换 `--dataset_mode`
- 其余代码零改动

框架的价值大于模型本身。读完应该能回答两个问题：**新算法怎么挂进去**、**新数据怎么接进来**。

---

## 2. 两篇论文与两种任务

| | CycleGAN | pix2pix |
|---|---|---|
| 论文 | Unpaired Image-to-Image Translation using Cycle-Consistent Adversarial Networks | Image-to-Image Translation with Conditional Adversarial Networks |
| 会议 | ICCV 2017 | CVPR 2017 |
| 配对要求 | 无需配对（unpaired） | 必须成对（paired） |
| 典型场景 | 马↔斑马、夏↔冬、照片↔油画 | 线稿→上色、语义图→照片、黑白→彩色 |
| 核心约束 | 循环一致性（cycle-consistency） | 条件 GAN + L1 重建 |

关键差异一句话：**pix2pix 靠「成对的监督信号」约束输出，CycleGAN 靠「绕一圈能回到原点」约束输出。**

---

## 3. 仓库目录结构

```
pytorch-CycleGAN-and-pix2pix/
├── train.py                    # 通用训练脚本
├── test.py                     # 通用测试/推理脚本
├── options/
│   ├── base_options.py         # 训练+测试共用选项，含动态注入机制
│   ├── train_options.py        # 仅训练期选项（niter / lr_policy / ...）
│   └── test_options.py         # 仅测试期选项（num_test / results_dir / eval）
├── data/
│   ├── __init__.py             # create_dataset / find_dataset_using_name
│   ├── base_dataset.py         # BaseDataset 抽象基类 + 图像变换工具
│   ├── image_folder.py         # 支持递归子目录的 ImageFolder
│   ├── aligned_dataset.py      # 配对数据（一张 AB 拼图从中间切开）
│   ├── unaligned_dataset.py    # 非配对数据（trainA / trainB）
│   ├── single_dataset.py       # 单域图片（配合 --model test 单向推理）
│   ├── colorization_dataset.py # RGB → (L, ab) 色彩空间拆分
│   └── template_dataset.py     # 官方填空模板
├── models/
│   ├── __init__.py             # create_model / find_model_using_name
│   ├── base_model.py           # BaseModel 抽象基类 + 保存/加载/调度器
│   ├── pix2pix_model.py        # pix2pix
│   ├── cycle_gan_model.py      # CycleGAN
│   ├── colorization_model.py   # Pix2PixModel 的子类，做上色
│   ├── test_model.py           # 单向推理专用
│   ├── networks.py             # 所有网络结构 + GANLoss + 初始化 + 调度器
│   └── template_model.py       # 官方填空模板
├── util/
│   ├── visualizer.py           # visdom 曲线 + HTML 结果页
│   ├── image_pool.py           # 假图历史缓冲
│   ├── html.py                 # 基于 dominate 的 HTML 生成
│   ├── util.py                 # tensor2im / mkdirs / diagnose_network
│   └── get_data.py             # 数据下载
├── scripts/                    # 一堆现成 shell 脚本 + 预训练模型下载
├── datasets/                   # 数据下载脚本 + combine_A_and_B.py
├── docs/                       # overview / tips / qa / datasets / docker
└── checkpoints/  results/      # 运行时产出
```

---

## 4. 四个关键设计模式

### 4.1 ABC + 模板方法

`BaseModel` 定义了骨架方法：

| 骨架方法 | 职责 |
|---|---|
| `setup(opt)` | 建调度器、按需加载权重、打印网络参数量 |
| `test()` | `no_grad` 包住 `forward()` + `compute_visuals()` |
| `eval()` | 切 eval 模式 |
| `save_networks / load_networks` | 权重存取，含 InstanceNorm 旧版兼容补丁 |
| `update_learning_rate()` | 逐 epoch 调调度器 |
| `get_current_losses / get_current_visuals` | 按名字列表反射取属性 |

子类只需实现四个钩子：

- `__init__`（先调 `BaseModel.__init__(self, opt)`）
- `set_input(input)`
- `forward()`
- `optimize_parameters()`
- （可选）`modify_commandline_options(parser, is_train)`

`BaseDataset` 完全同构：`__init__` / `__len__` / `__getitem__` / `modify_commandline_options`。

### 4.2 按名字反射实例化

```python
# data/__init__.py 核心逻辑
dataset_filename = "data." + dataset_name + "_dataset"   # 'unaligned' -> data.unaligned_dataset
datasetlib = importlib.import_module(dataset_filename)
target_dataset_name = dataset_name.replace('_', '') + 'dataset'   # -> 'unaligneddataset'
for name, cls in datasetlib.__dict__.items():
    if name.lower() == target_dataset_name.lower() and issubclass(cls, BaseDataset):
        dataset = cls
```

命名约定：`--dataset_mode unaligned` → 文件 `data/unaligned_dataset.py` → 类 `UnalignedDataset`。

`models/__init__.py` 里的 `find_model_using_name` 与之完全对称。

**推论：新增一个算法 = 加一个文件 + 类名对上，不用改任何分发代码。**

### 4.3 选项也是插件

这是整个框架最巧的一处。`BaseOptions.gather_options()` 做三次解析：

```
第 1 次 parse  →  拿到 --model 和 --dataset_mode
      ↓
调用 models.get_option_setter(model_name)(parser, isTrain)      # 注入模型专有选项 + 改默认值
调用 data.get_option_setter(dataset_name)(parser, isTrain)      # 注入数据集专有选项 + 改默认值
      ↓
第 3 次 parse  →  正式参数
```

这就是「换模型时默认值自动跟着换」的机制：

| 参数 | 全局默认 | CycleGAN 改成 | pix2pix 改成 |
|---|---|---|---|
| `netG` | `resnet_9blocks` | （沿用） | `unet_256` |
| `netD` | `basic` | （沿用） | （沿用） |
| `norm` | `instance` | （沿用） | `batch` |
| `dataset_mode` | `unaligned` | （沿用） | `aligned` |
| `no_dropout` | False | **True** | False |
| `pool_size` | 50 | （沿用） | **0** |
| `gan_mode` | `lsgan` | （沿用） | **`vanilla`** |

### 4.4 命名约定驱动可视化

模型只声明三个字符串列表：

```python
self.loss_names   = ['G_GAN', 'G_L1', 'D_real', 'D_fake']    # pix2pix
self.visual_names = ['real_A', 'fake_B', 'real_B']
self.model_names  = ['G', 'D']
```

`BaseModel` 统一用反射取用：

```python
errors_ret[name] = float(getattr(self, 'loss_' + name))   # get_current_losses
net = getattr(self, 'net' + name)                          # save/load_networks
visual_ret[name] = getattr(self, name)                     # get_current_visuals
```

**推论：加新损失或新网络，不必改 `train.py` 和 `visualizer.py`。**

---

## 5. 数据流：从命令行到一次迭代

```
python train.py --dataroot ... --name ... --model ...
        │
        ├─ TrainOptions().parse()
        │     └─ gather_options()：三次解析 + 动态注入 → opt
        │
        ├─ create_dataset(opt)
        │     └─ find_dataset_using_name(opt.dataset_mode)
        │           └─ CustomDatasetDataLoader(opt)
        │                 ├─ dataset_class(opt)
        │                 └─ torch.utils.data.DataLoader(batch_size, shuffle, num_workers)
        │
        ├─ create_model(opt)
        │     └─ find_model_using_name(opt.model) → ModelClass(opt)
        │           ├─ define_G / define_D 建网络
        │           └─ 建 optimizer（Adam, betas=(beta1, 0.999)）
        │
        ├─ model.setup(opt)
        │     ├─ 建 lr_scheduler（linear / step / plateau / cosine）
        │     ├─ 若 continue_train 或测试期 → load_networks()
        │     └─ print_networks(verbose)
        │
        └─ Visualizer(opt) → 训练主循环
              for epoch in range(epoch_count, niter + niter_decay + 1):
                  for i, data in enumerate(dataset):
                      model.set_input(data)
                      model.optimize_parameters()
                      if total_iters % display_freq == 0: 视觉化
                      if total_iters % print_freq == 0:   打印损失
                      if total_iters % save_latest_freq == 0: 存 latest
                  model.save_networks('latest'); model.save_networks(epoch)
                  model.update_learning_rate()
```

---

## 6. 数据加载层（data/）

### 6.1 BaseDataset 与图像变换

`base_dataset.py` 除了定义 ABC，还提供全套变换函数：

```python
def get_params(opt, size):
    # 决定 crop 起点和是否翻转；注意随机范围用 np.maximum(0, ...) 兜底
    x = random.randint(0, np.maximum(0, new_w - opt.crop_size))
    y = random.randint(0, np.maximum(0, new_h - opt.crop_size))
    flip = random.random() > 0.5
    return {'crop_pos': (x, y), 'flip': flip}
```

`--preprocess` 五种取值的行为：

| 取值 | 行为 |
|---|---|
| `resize_and_crop`（默认） | 先 resize 到 `(load_size, load_size)`，再随机 crop 到 `crop_size` |
| `crop` | 不 resize，直接随机 crop |
| `scale_width` | resize 使宽度等于 `crop_size`，保持长宽比 |
| `scale_width_and_crop` | 先 scale 宽度到 `load_size`，再 crop |
| `none` | 跳过，但仍会把图调到 4 的倍数 |

**关键约束**：`__make_power_2(img, base=4)` —— 即使 `--preprocess none` 也会把尺寸调整为 4 的倍数，因为生成器有两次下采样，输入输出尺寸不一致会导致 L1 损失无法计算。

```python
def __make_power_2(img, base, method=Image.BICUBIC):
    ow, oh = img.size
    h = int(round(oh / base) * base)
    w = int(round(ow / base) * base)
    ...
```

归一化统一为 `Normalize((0.5,), (0.5,))`（灰度）或 `Normalize((0.5,0.5,0.5), (0.5,0.5,0.5))`（RGB），即映射到 `[-1, 1]`——这与生成器末层 `Tanh()` 匹配。

### 6.2 AlignedDataset：配对数据的核心约定

```python
AB_path = self.AB_paths[index]
AB = Image.open(AB_path).convert('RGB')
w, h = AB.size
w2 = int(w / 2)
A = AB.crop((0, 0, w2, h))       # 左半边 = A
B = AB.crop((w2, 0, w, h))       # 右半边 = B

# 关键：A、B 共享同一组 transform 参数，保证空间对齐
transform_params = get_params(self.opt, A.size)
A_transform = get_transform(self.opt, transform_params, grayscale=(self.input_nc == 1))
B_transform = get_transform(self.opt, transform_params, grayscale=(self.output_nc == 1))
```

要点：

1. 数据集里存的是**一张横向拼接的 AB 图**，从中间切开。
2. A、B 共享 `transform_params`，这是「配对」在代码层面的真正含义——**随机增强必须同步**。
3. 目录假设：`/path/to/data/train/` 放训练拼图，测试时用 `/path/to/data/test/`。
4. `direction` 在 `__init__` 里交换 `input_nc` / `output_nc`：`--direction BtoA` 时输入是 B、输出是 A。

配套工具 `datasets/combine_A_and_B.py`：把 `/data/A/train/1.jpg` 和 `/data/B/train/1.jpg` 横向拼成一张。**要求同名、同尺寸。**

### 6.3 UnalignedDataset

目录假设：`trainA/`、`trainB/`（测试 `testA/`、`testB/`）。A、B 各自独立随机增强，不需要对齐。

### 6.4 SingleDataset

只加载一个目录的图片，配合 `--model test` 做单向推理，输出只有 `real` 和 `fake`。

### 6.5 ColorizationDataset

把 RGB 转到 Lab 空间，L 通道做输入（1 通道），ab 通道做输出（2 通道）。自动设置 `--input_nc 1`、`--output_nc 2`。

### 6.6 CustomDatasetDataLoader

```python
self.dataloader = torch.utils.data.DataLoader(
    self.dataset,
    batch_size=opt.batch_size,
    shuffle=not opt.serial_batches,
    num_workers=int(opt.num_threads))
```

`__len__` 返回 `min(len(dataset), max_dataset_size)`；`__iter__` 也按 `max_dataset_size` 提前 break。

---

## 7. 模型层（models/）

### 7.1 Pix2PixModel

```python
# 默认值改写
parser.set_defaults(norm='batch', netG='unet_256', dataset_mode='aligned')
parser.set_defaults(pool_size=0, gan_mode='vanilla')
parser.add_argument('--lambda_L1', type=float, default=100.0)
```

结构：

- `model_names = ['G', 'D']`（测试期只有 `['G']`）
- `loss_names = ['G_GAN', 'G_L1', 'D_real', 'D_fake']`
- `visual_names = ['real_A', 'fake_B', 'real_B']`
- 判别器输入通道数 = `input_nc + output_nc`（**条件 GAN 的关键**）

前向与损失：

```python
def forward(self):
    self.fake_B = self.netG(self.real_A)          # G(A)

def backward_D(self):
    fake_AB = torch.cat((self.real_A, self.fake_B), 1)
    pred_fake = self.netD(fake_AB.detach())       # detach 截断对 G 的梯度
    self.loss_D_fake = self.criterionGAN(pred_fake, False)
    real_AB = torch.cat((self.real_A, self.real_B), 1)
    pred_real = self.netD(real_AB)
    self.loss_D_real = self.criterionGAN(pred_real, True)
    self.loss_D = (self.loss_D_fake + self.loss_D_real) * 0.5
    self.loss_D.backward()

def backward_G(self):
    fake_AB = torch.cat((self.real_A, self.fake_B), 1)
    self.loss_G_GAN = self.criterionGAN(self.netD(fake_AB), True)
    self.loss_G_L1 = self.criterionL1(self.fake_B, self.real_B) * self.opt.lambda_L1
    self.loss_G = self.loss_G_GAN + self.loss_G_L1
    self.loss_G.backward()
```

优化顺序：**先 D 后 G**。

```python
def optimize_parameters(self):
    self.forward()
    self.set_requires_grad(self.netD, True)
    self.optimizer_D.zero_grad(); self.backward_D(); self.optimizer_D.step()
    self.set_requires_grad(self.netD, False)      # 更新 G 时冻结 D
    self.optimizer_G.zero_grad(); self.backward_G(); self.optimizer_G.step()
```

### 7.2 CycleGANModel

```python
parser.set_defaults(no_dropout=True)              # 原论文不用 dropout
parser.add_argument('--lambda_A', type=float, default=10.0)
parser.add_argument('--lambda_B', type=float, default=10.0)
parser.add_argument('--lambda_identity', type=float, default=0.5)
```

命名对照（源码注释里明确写了）：

| 代码 | 论文 |
|---|---|
| `G_A` | G（A→B） |
| `G_B` | F（B→A） |
| `D_A` | D_Y（判 B） |
| `D_B` | D_X（判 A） |

四个网络：`define_G` 两次 + `define_D` 两次。优化器用 `itertools.chain` 把两个生成器、两个判别器分别打包：

```python
self.optimizer_G = torch.optim.Adam(
    itertools.chain(self.netG_A.parameters(), self.netG_B.parameters()),
    lr=opt.lr, betas=(opt.beta1, 0.999))
self.optimizer_D = torch.optim.Adam(
    itertools.chain(self.netD_A.parameters(), self.netD_B.parameters()),
    lr=opt.lr, betas=(opt.beta1, 0.999))
```

前向：

```python
def forward(self):
    self.fake_B = self.netG_A(self.real_A)   # G_A(A)
    self.rec_A  = self.netG_B(self.fake_B)   # G_B(G_A(A))  ← 正向循环
    self.fake_A = self.netG_B(self.real_B)   # G_B(B)
    self.rec_B  = self.netG_A(self.fake_A)   # G_A(G_B(B))  ← 反向循环
```

判别器使用图像池：

```python
def backward_D_A(self):
    fake_B = self.fake_B_pool.query(self.fake_B)     # 50% 概率返回历史假图
    self.loss_D_A = self.backward_D_basic(self.netD_A, self.real_B, fake_B)
```

生成器损失含 identity 分支（仅当 `input_nc == output_nc` 才允许启用）：

```python
if lambda_idt > 0:
    assert(opt.input_nc == opt.output_nc)
    self.idt_A = self.netG_A(self.real_B)
    self.loss_idt_A = self.criterionIdt(self.idt_A, self.real_B) * lambda_B * lambda_idt
    self.idt_B = self.netG_B(self.real_A)
    self.loss_idt_B = self.criterionIdt(self.idt_B, self.real_A) * lambda_A * lambda_idt
```

优化顺序：**先 G 后 D**（与 pix2pix 相反）。

### 7.3 TestModel

配合 `--model test` 使用，自动把 `--dataset_mode` 设为 `single`，只加载单侧生成器（用 `--model_suffix _A` 或 `_B` 指定）。这是显存紧张时的救命选项。

### 7.4 ColorizationModel

`Pix2PixModel` 的子类，重写 `set_input` 把 ab 通道拆成 B，并覆盖 `compute_visuals` 把 Lab 拼回 RGB。

### 7.5 BaseModel 的两个细节

**InstanceNorm 旧版兼容补丁**：

```python
def __patch_instance_norm_state_dict(self, state_dict, module, keys, i=0):
    if module.__class__.__name__.startswith('InstanceNorm') and \
            (key == 'running_mean' or key == 'running_var'):
        if getattr(module, key) is None:
            state_dict.pop('.'.join(keys))
    if module.__class__.__name__.startswith('InstanceNorm') and \
            (key == 'num_batches_tracked'):
        state_dict.pop('.'.join(keys))
```

**cudnn.benchmark 的条件开关**：

```python
if opt.preprocess != 'scale_width':   # scale_width 时图片尺寸不一致，benchmark 反而有害
    torch.backends.cudnn.benchmark = True
```

---

## 8. 网络结构（networks.py）

### 8.1 生成器

**ResnetGenerator**（CycleGAN 默认，`resnet_9blocks` / `resnet_6blocks`）

```
ReflectionPad2d(3)
→ Conv2d(input_nc, ngf, k=7) + norm + ReLU
→ [下采样 ×2]  Conv2d(k=3, stride=2, padding=1) + norm + ReLU
→ [ResnetBlock × n_blocks]      # 9 或 6
→ [上采样 ×2]  ConvTranspose2d(k=3, stride=2, padding=1, output_padding=1) + norm + ReLU
→ ReflectionPad2d(3) + Conv2d(ngf, output_nc, k=7) + Tanh
```

`use_bias` 的判定逻辑值得记住：

```python
if type(norm_layer) == functools.partial:
    use_bias = norm_layer.func == nn.InstanceNorm2d
else:
    use_bias = norm_layer == nn.InstanceNorm2d
```

即：**用 InstanceNorm 时卷积需要 bias，用 BatchNorm 时不需要**（BN 自带 affine）。

**UnetGenerator**（pix2pix 默认，`unet_256` / `unet_128`）

从最内层往外递归构造：

```python
unet_block = UnetSkipConnectionBlock(ngf*8, ngf*8, innermost=True)
for i in range(num_downs - 5):
    unet_block = UnetSkipConnectionBlock(ngf*8, ngf*8, submodule=unet_block, use_dropout=use_dropout)
unet_block = UnetSkipConnectionBlock(ngf*4, ngf*8, submodule=unet_block)
unet_block = UnetSkipConnectionBlock(ngf*2, ngf*4, submodule=unet_block)
unet_block = UnetSkipConnectionBlock(ngf,   ngf*2, submodule=unet_block)
self.model = UnetSkipConnectionBlock(output_nc, ngf, input_nc=input_nc, outermost=True)
```

`UnetSkipConnectionBlock` 的三种形态：

| 形态 | down | up |
|---|---|---|
| outermost | `[downconv]` | `[ReLU, upconv, Tanh]` |
| innermost | `[LeakyReLU, downconv]` | `[ReLU, upconv, norm]` |
| 中间层 | `[LeakyReLU, downconv, norm]` | `[ReLU, upconv, norm]`（+ 可选 Dropout） |

skip 连接在 `forward` 里：

```python
def forward(self, x):
    if self.outermost:
        return self.model(x)
    else:
        return torch.cat([x, self.model(x)], 1)   # 沿通道维拼接
```

**注意**：U-Net 的 skip 用的是 `cat`（拼接），不是 ResNet 的 `+`（相加）。

### 8.2 判别器

**NLayerDiscriminator**（PatchGAN，`basic` = n_layers 3）

- 70×70 感受野
- 全卷积，可处理任意尺寸输入
- 输出 **1 通道预测图**而不是单个标量
- 通道数按 `min(2**n, 8)` 增长，最多到 `ndf * 8`

**PixelDiscriminator**（`pixel`）

全 1×1 卷积，只看单像素真假，增强色彩多样性但不建模空间统计。

### 8.3 GANLoss：三种目标统一封装

```python
if gan_mode == 'lsgan':      self.loss = nn.MSELoss()
elif gan_mode == 'vanilla':  self.loss = nn.BCEWithLogitsLoss()
elif gan_mode in ['wgangp']: self.loss = None
```

用 `register_buffer` 存标签，`expand_as(prediction)` 免去手建 target：

```python
self.register_buffer('real_label', torch.tensor(target_real_label))
self.register_buffer('fake_label', torch.tensor(target_fake_label))

def get_target_tensor(self, prediction, target_is_real):
    target_tensor = self.real_label if target_is_real else self.fake_label
    return target_tensor.expand_as(prediction)
```

**注意**：判别器末层不要加 sigmoid —— vanilla 用 `BCEWithLogitsLoss`（自带 sigmoid），LSGAN 不需要。

WGAN-GP 分支额外提供 `cal_gradient_penalty()`，对 `real` / `fake` / `mixed` 三种插值方式计算梯度惩罚。

### 8.4 初始化与调度器

`init_weights` 支持 `normal`（默认，gain 0.02）/ `xavier` / `kaiming` / `orthogonal`；BatchNorm2d 的 weight 用 `normal_(1.0, gain)`、bias 置 0。

`get_scheduler` 支持四种 `lr_policy`：

| 策略 | 实现 |
|---|---|
| `linear`（默认） | 前 `niter` epoch 恒定，后 `niter_decay` epoch 线性衰减到 0 |
| `step` | `StepLR(step_size=lr_decay_iters, gamma=0.1)` |
| `plateau` | `ReduceLROnPlateau(mode='min', factor=0.2, threshold=0.01, patience=5)`，需传入 metric |
| `cosine` | `CosineAnnealingLR(T_max=niter, eta_min=0)` |

---

## 9. 损失函数逐项推导

### 9.1 pix2pix

条件 GAN 的目标：

```
L_cGAN(G, D) = E[log D(x, y)] + E[log(1 − D(x, G(x)))]
```

加 L1 重建（论文实验证明 L1 比 L2 更少模糊）：

```
G* = argmin_G max_D L_cGAN(G, D) + λ · ||y − G(x)||₁ ,   λ = 100
```

源码对应：

```
loss_G = GAN(D(cat(A, G(A))), 真) + 100 · ‖G(A) − B‖₁
loss_D = ½ · [ GAN(D(cat(A, B)), 真) + GAN(D(cat(A, G(A)).detach()), 假) ]
```

### 9.2 CycleGAN

对抗损失（两个方向）：

```
L_GAN = E[log D_B(b)] + E[log(1 − D_B(G_A(a)))]
      + E[log D_A(a)] + E[log(1 − D_A(G_B(b)))]
```

循环一致性损失：

```
L_cyc = E[ ||G_B(G_A(a)) − a||₁ ] · λ_A  +  E[ ||G_A(G_B(b)) − b||₁ ] · λ_B
```

恒等损失（可选，λ_idt = 0.5）：

```
L_idt = E[ ||G_A(b) − b||₁ ] · λ_B · λ_idt  +  E[ ||G_B(a) − a||₁ ] · λ_A · λ_idt
```

总损失：

```
L(G_A, G_B, D_A, D_B) = L_GAN + L_cyc + L_idt
```

源码对应：

```python
self.loss_G = (self.loss_G_A + self.loss_G_B
               + self.loss_cycle_A + self.loss_cycle_B
               + self.loss_idt_A + self.loss_idt_B)
```

### 9.3 恒等损失到底在干什么

官方 FAQ 的解释值得原文引用：

> We use the identity loss for our photo to painting application. The identity loss can regularize the generator to be close to an identity mapping when fed with real samples from the *target* domain. If something already looks like from the target domain, you should preserve the image without making additional changes. The generator trained with this loss will often be more conservative for unknown content.

即：**「输入已经是目标域的样子时，别乱改」**。副作用是生成结果更保守、变化幅度更小。原始想法来自 Taigman et al. 2017 的 Equation 6。

### 9.4 两个必须注意的工程细节

1. **更新 D 时对假样本 `detach()`** —— 否则梯度会回传到 G。
2. **更新 G 前 `set_requires_grad(D, False)`** —— 省算力，同时避免意外更新 D。

---

## 10. 训练/测试循环

### 10.1 train.py

```python
for epoch in range(opt.epoch_count, opt.niter + opt.niter_decay + 1):
    for i, data in enumerate(dataset):
        visualizer.reset()
        total_iters += opt.batch_size
        epoch_iter += opt.batch_size
        model.set_input(data)
        model.optimize_parameters()

        if total_iters % opt.display_freq == 0:      # 默认 400
            save_result = total_iters % opt.update_html_freq == 0
            model.compute_visuals()
            visualizer.display_current_results(model.get_current_visuals(), epoch, save_result)

        if total_iters % opt.print_freq == 0:        # 默认 100
            losses = model.get_current_losses()
            visualizer.print_current_losses(epoch, epoch_iter, losses, t_comp, t_data)
            if opt.display_id > 0:
                visualizer.plot_current_losses(epoch, float(epoch_iter) / dataset_size, losses)

        if total_iters % opt.save_latest_freq == 0:  # 默认 5000
            save_suffix = 'iter_%d' % total_iters if opt.save_by_iter else 'latest'
            model.save_networks(save_suffix)

    if epoch % opt.save_epoch_freq == 0:             # 默认 5
        model.save_networks('latest'); model.save_networks(epoch)
    model.update_learning_rate()
```

### 10.2 test.py 的硬编码

```python
opt.num_threads = 0        # 注释写的是 1，实际是 0
opt.batch_size = 1
opt.serial_batches = True  # 按顺序取图
opt.no_flip = True
opt.display_id = -1        # 不连 visdom，只存 HTML
```

**这些值会覆盖命令行参数** —— 测试时改这几个 flag 无效。

推理用 `model.test()`，内部 `torch.no_grad()` 包住 `forward()` + `compute_visuals()`。

---

## 11. 命令行选项体系

### 11.1 BaseOptions 关键参数

| 分组 | 参数 | 默认 | 说明 |
|---|---|---|---|
| 基础 | `--dataroot` | 必填 | 数据根目录 |
| | `--name` | `experiment_name` | 实验名，决定 checkpoint 路径 |
| | `--gpu_ids` | `0` | `-1` 为 CPU；`0,1,2` 多卡 |
| | `--checkpoints_dir` | `./checkpoints` | |
| 模型 | `--model` | `cycle_gan` | `cycle_gan / pix2pix / test / colorization` |
| | `--input_nc` / `--output_nc` | 3 / 3 | 灰度图改 1 |
| | `--ngf` / `--ndf` | 64 / 64 | 生成器末层 / 判别器首层通道数 |
| | `--netG` | `resnet_9blocks` | 见 8.1 |
| | `--netD` | `basic` | `basic / n_layers / pixel` |
| | `--n_layers_D` | 3 | 仅 `netD=n_layers` 时生效 |
| | `--norm` | `instance` | `instance / batch / none` |
| | `--init_type` / `--init_gain` | `normal` / 0.02 | |
| | `--no_dropout` | False | CycleGAN 自动置 True |
| 数据 | `--dataset_mode` | `unaligned` | `unaligned / aligned / single / colorization` |
| | `--direction` | `AtoB` | 或 `BtoA` |
| | `--serial_batches` | False | True 则不打乱 |
| | `--num_threads` | 4 | |
| | `--batch_size` | 1 | |
| | `--load_size` / `--crop_size` | 286 / 256 | |
| | `--max_dataset_size` | inf | |
| | `--preprocess` | `resize_and_crop` | 见 6.1 |
| | `--no_flip` | False | |
| | `--display_winsize` | 256 | |
| 其他 | `--epoch` | `latest` | 加载哪个 epoch |
| | `--load_iter` | 0 | >0 时按 `iter_N` 加载 |
| | `--verbose` | False | 打印网络结构 |
| | `--suffix` | `''` | 追加到 `name` 后 |

### 11.2 各脚本的默认值差异（重要）

| 参数 | base 默认 | CycleGAN 覆盖 | pix2pix 覆盖 |
|---|---|---|---|
| `netG` | `resnet_9blocks` | — | `unet_256` |
| `norm` | `instance` | — | `batch` |
| `dataset_mode` | `unaligned` | — | `aligned` |
| `no_dropout` | False | **True** | — |
| `pool_size` | 50 | — | **0** |
| `gan_mode` | `lsgan` | — | **`vanilla`** |
| 新增参数 | — | `lambda_A`=10, `lambda_B`=10, `lambda_identity`=0.5 | `lambda_L1`=100 |

---

## 12. 上手命令速查

```bash
# ---------- 安装 ----------
pip install -r requirements.txt
# 或 conda
conda env create -f environment.yml
# 或 Docker：见 docs/docker.md

# ---------- 数据 ----------
bash ./datasets/download_cyclegan_dataset.sh maps
bash ./datasets/download_pix2pix_dataset.sh facades

# ---------- 可视化（可选） ----------
python -m visdom.server      # http://localhost:8097

# ---------- CycleGAN 训练 / 测试 ----------
python train.py --dataroot ./datasets/maps --name maps_cyclegan --model cycle_gan
python test.py  --dataroot ./datasets/maps --name maps_cyclegan --model cycle_gan
# 结果：./results/maps_cyclegan/latest_test/index.html

# ---------- pix2pix 训练 / 测试 ----------
python train.py --dataroot ./datasets/facades --name facades_pix2pix --model pix2pix --direction BtoA
python test.py  --dataroot ./datasets/facades --name facades_pix2pix --model pix2pix --direction BtoA
# 结果：./results/facades_pix2pix/test_latest/index.html

# ---------- 预训练模型 ----------
bash ./scripts/download_cyclegan_model.sh horse2zebra
python test.py --dataroot datasets/horse2zebra/testA --name horse2zebra_pretrained \
               --model test --no_dropout

bash ./scripts/download_pix2pix_model.sh facades_label2photo
python test.py --dataroot ./datasets/facades/ --direction BtoA \
               --model pix2pix --name facades_label2photo_pretrained

# ---------- 常用开关 ----------
--gpu_ids -1              # 纯 CPU
--gpu_ids 0,1,2,3         # 多卡
--display_id 0            # 关 visdom（0 或 -1）
--no_html                 # 不写 HTML 结果页
--continue_train --epoch_count 10   # 续训 / 微调
--verbose                 # 打印网络结构

# ---------- 自建配对数据 ----------
python datasets/combine_A_and_B.py --fold_A /path/to/A --fold_B /path/to/B --fold_AB /path/to/data

# ---------- 高分辨率策略 ----------
# 训练：scale_width_and_crop + load_size 1024 + crop_size 360
# 测试：scale_width + load_size 1024
```

---

## 13. 高频踩坑（docs/qa.md 精华）

| 现象 | 原因 | 解决 |
|---|---|---|
| `ConnectionRefusedError` / `HTTPConnectionPool` | visdom 没启动 | `python -m visdom.server` 或 `--display_id 0` |
| `ValueError: empty range for randrange()` | `--preprocess crop` 时图片小于 `crop_size` | 改用 `resize_and_crop` / `scale_width_and_crop`，保证 `load_size ≥ crop_size` |
| `AttributeError: module 'torch' has no attribute 'device'`<br>`Tensor is not JSON serializable` | PyTorch < 0.4 | 升级到 0.4+ |
| 训练损失不收敛 | GAN 极小极大优化的本性 | DCGAN/LSGAN 下 G、D 损失上下波动**属正常**，只要不爆炸就行；判断收敛要看生成样本 |
| OOM | CycleGAN 需同时驻留 2G+2D | 训练用 crop；测试用 `--model test --model_suffix _A --preprocess none` 只加载单侧 |
| 输出尺寸与输入不符 | 生成器有两次下采样 | 尺寸必须是 4 的倍数；`--crop_size` 也必须是 4 的倍数 |
| 多卡训练效果差 | BatchNorm 参数不跨 GPU 共享 | `--norm instance`（或同步 BN），并加大 `batch_size` |
| 训练早期颜色反转且再也不恢复 | 生成器不必要的颜色翻转 | 加大 identity loss（`--lambda_identity 0.1` 或 `1.0`），或调小 `--init_gain` |
| 棋盘格伪影 | 反卷积导致 | 换成 `Upsample(bilinear) + ReflectionPad2d + Conv2d`；或训练更久 |
| 想要输出多样性但没有 | pix2pix/CycleGAN 生成器不吃噪声 z | 条件 GAN 不需要 z（输入本身充当 z），映射是确定的；要多样性看 BicycleGAN / MUNIT / DRIT / AugmentedCycleGAN |
| Cityscapes FCN 评分偏低 | 预训练模型在 256×256 上训练、上采样到 1024×2048 | 评估前把原图 resize 到 256×256 |
| 想跑 16-bit png / tiff / 高光谱 | 代码只支持 RGB 和灰度 | 改 `--input_nc` / `--output_nc` + 写自定义 dataset（对齐改 `aligned_dataset.py:41`，非配对改 `unaligned_dataset.py:57`） |

---

## 14. 如何扩展：自定义模型与数据集

### 14.1 新增数据集（以 `dummy` 为例）

1. 新建 `data/dummy_dataset.py`，定义 `DummyDataset(BaseDataset)`
2. 实现 `__init__`（首行调 `BaseDataset.__init__(self, opt)`）、`__len__`、`__getitem__`
3. 可选实现 `modify_commandline_options(parser, is_train)`
4. 用 `--dataset_mode dummy` 启用

**注意命名**：`find_dataset_using_name` 匹配的是「去下划线 + 小写」后的类名，所以 `dummy` → `DummyDataset` 能对上，`dummy_thing` → `DummythingDataset`（不是 `DummyThingDataset`）。

### 14.2 新增模型（以 `dummy` 为例）

1. 新建 `models/dummy_model.py`，定义 `DummyModel(BaseModel)`
2. 实现 `__init__`（首行调 `BaseModel.__init__(self, opt)`，并填好 `loss_names` / `model_names` / `visual_names` / `optimizers`）
3. 实现 `set_input`、`forward`、`optimize_parameters`
4. 可选实现 `modify_commandline_options(parser, is_train)`
5. 用 `--model dummy` 启用

### 14.3 官方模板

直接抄这两个文件当脚手架：

- `data/template_dataset.py`
- `models/template_model.py`

### 14.4 提交前自检

```bash
flake8 --ignore E501 .
python ./scripts/test_before_push.py
```

若增删了文件，记得同步更新 `docs/overview.md`。

---

## 15. 阅读后的评价与适用边界

### 值得学的

1. **选项注入机制**是这套代码最优雅的地方 —— 用「先解析一次拿名字，再让插件改 parser，最后正式解析」解决了「不同模型需要不同默认值」的问题，避免了层层 `if model == ...`。
2. **反射式分发**把「加算法」的成本压到最低：一个文件 + 一个类名。
3. **命名约定驱动可视化**让 `train.py` 完全通用，模型自己声明要记录什么。
4. **模板文件**（`template_*.py`）是很实在的工程习惯 —— 扩展点写清楚，别人不用猜。

### 需要注意的边界

1. **代码风格偏老**：`Image.BICUBIC`、`parser.add_argument('--max_dataset_size', default=float("inf"))` 这类写法在新版 PyTorch/torchvision 下需要改（`Image.BICUBIC` → `Image.Resampling.BICUBIC`）。
2. **只支持 RGB / 灰度**，多通道数据必须自己改 dataset。
3. **CycleGAN 显存开销是 pix2pix 的约 2 倍**（4 个网络），高分辨率场景必须走 crop + 单向推理的路子。
4. **损失曲线不可靠**：官方明确说 GAN 的 loss 曲线信息量很低，判断收敛要**定期生成样本肉眼看**。
5. **生成器确定性**：pix2pix / CycleGAN 都不吃随机噪声，同一输入永远同一输出。这是设计选择（论文里试过加 z 但效果不明显），不是 bug。

### 一句话总结

**这套仓库真正的价值是「框架范式」，不是两个模型。** 学会它的扩展点之后，任何 image-to-image 的新想法（新损失、新网络、新数据组织）都能在几十分钟内挂进这条流水线跑起来。

---

## 附：参考链接

- 仓库：<https://github.com/junyanz/pytorch-CycleGAN-and-pix2pix>
- CycleGAN 论文：<https://arxiv.org/pdf/1703.10593.pdf>
- pix2pix 论文：<https://arxiv.org/pdf/1611.07004.pdf>
- CycleGAN 项目页：<https://junyanz.github.io/CycleGAN/>
- pix2pix 项目页：<https://phillipi.github.io/pix2pix/>
- 代码结构总览：`docs/overview.md`
- 训练/测试技巧：`docs/tips.md`
- 常见问题：`docs/qa.md`
- 数据集说明：`docs/datasets.md`
- Docker 部署：`docs/docker.md`
- 相关项目：pix2pixHD、BicycleGAN、vid2vid、SPADE/GauGAN、iGAN、GAN Dissection、GAN Paint
