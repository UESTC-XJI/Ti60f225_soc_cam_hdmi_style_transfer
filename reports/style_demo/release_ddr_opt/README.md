# DDR 优化发布

分支 codex/monet-style-demo，起点 e8ff563。未连接或操作开发板。

等待计数、32-beat 显示缓冲、按 FIFO/行期限读优先与 CNN 三次绕过上限。模型/权重未变。

640×48 对照：2269633 → 1029441 周期；640×480 并发：10242677 周期，68.974ms，14.498 task fps（DDR 行为模型、单帧密集抓帧、无外层 CPU 竞争）。全部 CNN/抓帧像素对拍通过，显示欠载 0；不是板上 FPS。

XLR 58665/60800，RAM 256/256，DSP 140/160。CNN setup +0.502ns，100MHz setup +2.243ns，最小已报告 hold +0.026ns。

新 ti60f225_oob.bit 与 soc_video_app.elf 配套使用。旧 release 不覆盖。诊断寄存器、UART 字段、仿真范围和后续上板流程见 docs/DDR_READ_OPTIMIZATION.md。
