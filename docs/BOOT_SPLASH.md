# 启动图片与原画单画面

本版采用用户提供的 `assets/boot/source.png`，保留蓝底、Logo、文字及布局；输出为 1280×720。用于实际硬件的图片为 256×144、256 色索引 ROM，5 倍最近邻显示，预览见 `assets/boot/rom_preview.png`。`screen_1280x720.png` 是高分辨率参考图，实际 ROM 版本的细节较少。

## 启动顺序

1. CPU 进入 main 后写 0xF8100138=1，重新播放启动图，包含 IDE 重新下载固件的场景。
2. 稳定 720p60 同步下播放 16 级渐入约 0.8 秒、停留约 1 秒、渐出约 0.8 秒。每个亮度台阶保持 3 帧，RGB 颜色由初始化的片内 RAM 查表得到，无运行时 RGB 乘法器。
3. 动画完成后固件执行 DDR 测试、风格权重初始化和摄像头初始化。期间保持黑屏与 HDMI 同步。
4. 固件写 0xF8100138=2，允许显示实际采集的画面；硬件等待有效 display slot，并在 VS 边界切换。当前 frame store 在推理完成后发布配对的 raw/result slot，原画启动因此也等待首个推理任务完成。
5. 默认原画单画面：640×480 原画放大为 960×720，左右各 160 像素黑边，保持 4:3 比例。首次稳定的实体旋钮变更或 KNOB/SLOT 风格选择会转入单风格显示；上电读取旋钮只准备对应权重，不覆盖原画启动模式。KEY1/VIEW 仍切换对比和单风格。

摄像头初始化失败仍保留原有重试机制；没有有效图像时不会显示未写好的 DDR 内容。动画状态超时会增加 app_boot_errors 并停止初始化，可在 IDE 查看。状态为 app_boot_stage：1 动画，2 初始化，3 已允许视频切换。硬件实际切换由 BOOT_STATUS bit2 判断。

## 存储与资源

图片索引 36,864 字节，预计算亮度调色板 4,096×24 位（12,288 字节）；二者映射到 48 块片内 RAM。综合显示启动模块约 256 个 XLR、48 块 RAM、0 DSP。全工程第一轮综合/打包为 XLR 60,408/60,800，RAM 250/256，DSP 147/160；最终时序以交付报告为准。

这些 ROM 初值进入 bitstream，使用该位流配置后即可读取。当前工程仍使用 JTAG 下载 bit+ELF；断电自动启动需另外制作 Flash 固件启动镜像。

## 寄存器和协议

- 0xF8100130：bit0=FPS，bit1=对比，bit2=原画单画面（bit1=0 时有效），复位值 5。
- 0xF8100138：写 bit0=1 重新播放并撤销视频放行；写 2 允许后续有效帧切换。读 bit0 是请求 toggle，bit1 是视频放行。
- 0xF810013C：bit0=动画 busy，bit1=动画 done，bit2=已切换实时视频；只读，双级同步至 APB。
- `VIEW,0` 单风格，`VIEW,1` 对比，新增 `VIEW,2` 原画单画面。STATE 返回实际 VIEW，网页能识别原画状态。
- UART0 128000 8N1、1500 B/s、原有 BANK 0～4、快照 320×240 保持。

## 构建与验证

- `python tools/build_boot_asset.py`：从源图重建索引 ROM、渐变调色板和预览图，依赖 Pillow。
- `python tools/build_firmware.py`：重建完整固件。
- `python tools/test_boot_firmware.py`：实际 RV32 ELF 的 main 流程验证；外设驱动入口建模，验证动画完成前不初始化设备、原画默认值、初始化后放行。
- `tests/boot_splash_tb.sv`：亮度顺序、停留、完成、有效帧等待、VS 切换、再次启动。
- `tests/boot_splash_pixels_tb.sv`：完整 720p 帧逐像素对比 ROM 图像，验证同步与像素流水延迟。
- `tests/tb_disp_boot_modes.sv`：原画、对比、单风格的实际 AXI 读取与逐像素验证，帧中切模式。
- 原有 `tools/test_qse_mainline.py`、`tools/test_qse_mainline_rtl.py`、`tools/ble_web/test_mainline_ui.js` 覆盖按键/协议/快照/APB/网页。

FPGA 新输出在 work/boot_splash_fpga；旧 outflow 和已交付的 qse_mainline_merge_20261030 不覆盖。必须使用本版配套 bit 与 ELF。

最终构建 map/interface/pnr/pgm 全 PASS；全部已分析 setup/hold 关系为正，最小 setup +0.098 ns，最小 hold +0.028 ns。产物位于 deliverable/boot_splash_20261030。尚未自动烧写硬件，实板验收待完成。
