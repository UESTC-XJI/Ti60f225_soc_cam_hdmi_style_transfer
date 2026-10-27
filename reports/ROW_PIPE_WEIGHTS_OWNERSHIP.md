# 给模型侧：`rowpipe_weights.h` 的归属与换风格的正确姿势

> 2026-10-27　板侧/RTL 侧 → 模型/训练侧
> 状态：**新约定，即刻生效**。之前的做法会把板侧构建搞坏，而且不说话。

---

## 〇、一句话

**不要手改 `rowpipe_weights.h`。** 它是构建产物，不是源码。你继续换风格，但只写自己的导出目录，构建时点名，脚本会去取。

```bash
# 你只需要做这一件事
bash tools/build_firmware.sh redsky_v5
```

---

## 一、为什么（这不是流程洁癖，是真出过事）

`software/firmware/rowpipe_weights.h` 的性质是：**换风格时整份覆盖**（3612 个 word + XOR 全换）。
它不是那种"改一行"的源码文件。

于是两边同时写就会撞，而且**撞了不报错**：

| 时间 | 发生了什么 | 后果 |
|---|---|---|
| 10-26 20:41 | 有人改了这个文件 | 板侧正在做的 L11 实验参数被换掉 |
| 10-26 20:49 | 又改了一次 | 同上 |
| 10-27 15:03 | 被改回原版 `0xc7eaf900` | **板侧当时正在构建 redsky v5，编出来的 4 个固件里权重是错的**，直到最后核对才发现 |
| 10-27 15:38 | `git checkout` 恢复后几十秒内又被改写 | 证明是**持续写入**，不是偶发 |

这个文件我这边一天要读写十几次（换风格验证），所以撞车概率很高。

**关键点：撞车不会产生任何报错。** 固件照常 `PASS`，只是里面装的是别的权重。这种错误只能靠事后比对发现。

---

## 二、正确的分工

| 谁 | 写哪里 | 说明 |
|---|---|---|
| **模型侧（你）** | `demo/reports/rowpipe/export_<风格>/rowpipe_weights.h` | **源头**。一个风格一个目录，互不干扰 |
| **构建脚本** | `software/firmware/rowpipe_weights.h` | **派生品**。每次构建从导出目录整份复制 |
| **任何人** | ❌ 不要手改 firmware 下那份 | 改了白改（下次构建覆盖），而且会撞到正在跑的构建 |

一句话：**你的导出目录是唯一真相，firmware 下那份是缓存。**

---

## 三、新的构建用法

```bash
cd rowpipe_keys

# ① 推荐：点名风格（脚本自己去导出目录取权重）
bash tools/build_firmware.sh redsky_v5

# ② 直接给路径
bash tools/build_firmware.sh ../demo/reports/rowpipe/export_redsky_v5/rowpipe_weights.h

# ③ 不传参（用当前文件）—— 旧行为，仅在你明确知道当前文件是什么时用
bash tools/build_firmware.sh
```

支持三种导出目录命名，都会自动找到：

```
<导出根>/<名字>                       e.g. redsky_v5
<导出根>/export_<名字>                e.g. export_redsky_v5
<导出根>/export_<前缀>/<后缀>          e.g. export_starry/g075  ← starry_g075
```

导出根默认 `../demo/reports/rowpipe`，可用环境变量 `ROWPIPE_EXPORT_ROOT` 覆盖。

### 构建输出会自己报出"装的是哪套权重"

```
  权重 <- .../demo/reports/rowpipe/export_redsky_v5/rowpipe_weights.h
  权重：XOR=0xcbc67865  WORDS=3612
         ^ redsky v5（呐喊）
  ...
PASS complete application: .../soc_video_app.elf  [weights XOR=0xcbc67865]
```

意义："这个固件装的是哪套权重"从此是**构建日志的一部分**，不依赖任何人的记忆。

未登记的 XOR 会被明确提示，比如：

```
  权重：XOR=0xc7eaf900  WORDS=3612
         ^ ⚠ cap8-starry 原始 blob（不是 v5 家族，确认是有意的）
```

已登记：

| XOR | 风格 |
|---|---|
| `0xcbc67865` | **redsky v5（呐喊）** ← 当前交付目标 |
| `0x4a18e91c` | ink v5 |
| `0x58979045` | wave v5 |
| `0xf6a82050` | starry g075 |
| `0xcdc157c0` | starry g085 |
| `0xc7eaf900` | cap8-starry 原始 blob（**不是** v5 家族，慎用） |

> `scream` 已被 `redsky` 替代，不再作为交付目标（见 `docs/STYLE_LINEUP.md`）。

---

## 四、⚠ 一个技术提醒：RTL 现在会兜底，但不代表你的约定可以不改

今天板侧做了一个 RTL 修复（提交 `d376eee`）：**末层强制关 ReLU**。

```
rowpipe_engine.v: wire relu_dis = (L == NL-1)
                  ↓
requant.v:        ar = (relu_dis_r || (qlo_r < 0)) ? a : relu(a)
```

效果：**末层即使按 offset-binary 写成 `qlo=0/qhi=255`，也不会再被 ReLU 吃掉负半轴了。**

所以你现在用旧约定导出 starry，上板也能出正常图。**但这是 RTL 在替你的导出兜底**：

- 换到别的平台（没有这个 `relu_dis`）就会露馅
- 而且 `qlo=0` 的约定下，末层的量化区间是 `[0,255]`，配 `s_out = 1/255`
  —— 和 v5 家族用的 `[-127,127]` 差一个 offset，跨风格对比时会误导

**建议仍然按 v5 约定导出**：末层 `qlo=129（=有符号 −127）/ qhi=127`。理由见
`reports/FOR_MODEL_QUANT_CONTRACT.md`。

---

## 五、如果你要上板验证自己的权重

### 5.1 最快的路（不用重新烧固件）

板子跑起来、OpenOCD 连着的时候，**直接写 DDR**：

```bash
# 换权重（14,448 B），2 秒，网络下一帧就用新的
python tools/style_probe.py weights ../demo/reports/rowpipe/export_redsky_v5/rowpipe_blob.bin

# 量一下效果（σ / 三通道均值 / B−R / 平坦率 / 贴轨率）
python tools/style_probe.py stats --rows 240
```

这比"改固件 → 编译 → 烧录 → 重配 bit"快 **20 倍**，而且完全避开下面这个坑。

### 5.2 烧固件的话，有个必踩的坑

**每次重烧 ELF 都会锁存采集故障**：串口还在打，但 `MONET CAP 0 NN 0 MS 0`，屏幕黑。

**恢复方法：重配 bit**（`cmd //c _flash_new.bat`），不是 reset CPU。只 reset 清不掉。

---

## 六、怎么确认当前固件里是哪套权重

```bash
# 看构建日志（最简单）
grep "权重：" <构建输出>

# 或者事后核对：权重按字节原样嵌在 .bin 里
python -c "
blob=open('../demo/reports/rowpipe/export_redsky_v5/rowpipe_blob.bin','rb').read()
d=open('software/firmware/build/soc_video_app.bin','rb').read()
i=d.find(blob)
print('redsky_v5 在固件里:', '是' if i>=0 else '否', hex(i) if i>=0 else '')
"
```

⚠ **偏移不是固定的**（代码长度变了就变，实测见过 `0x34fc`/`0x3504`/`0x3490`/`0x3538`），
**永远用搜索，不要硬编码。**

---

## 七、如果你希望板侧配合

| 需求 | 怎么说 |
|---|---|
| 换一套风格上板 | "用 xxx 风格构建 + 烧板"（给风格名即可，导出目录里有就行） |
| 你的导出目录改名了 | 告诉我新名字，我把映射加进构建脚本 |
| 需要真实台架源帧做标定 | 说一声，我 dump `0x05000000`（一帧 2.8 分钟） |
| 想自己上板测 | 按 §五，优先用 DDR 直写（2 秒），不要每次烧固件 |

---

## 附：相关文档

| 文档 | 内容 |
|---|---|
| `docs/STYLE_LINEUP.md` | 风格清单（现存 3 套、scream 已废弃） |
| `reports/FOR_MODEL_QUANT_CONTRACT.md` | blob 量化契约（末层必须 `qlo<0`） |
| `reports/FOR_MODEL_FIRMWARE_GUIDE.md` | 改固件/编译/烧板/验证全流程 |
| `reports/REPLY_TO_MODEL_20s_experiment.md` | 线性 bias 修正的实测结论 |
