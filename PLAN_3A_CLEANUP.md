# 方案：删除硬件 AE/AWB/直方图，保留固件 3A 闭环

面向执行的 agent。请按顺序执行，每一步完成后立即跑该步对应的检查，最后统一回归。
本文所有文件路径相对 `ti60_style_demo/`。行号均为阅读时的近似位置，执行前以实际文件为准。

## 0. 目标与已确认决定

目标：硬件只负责采集最小的亮度和颜色统计，AE（传感器曝光）和 AWB（RGB 增益）全部由固件计算和控制。

已确认的决定：

1. AWB 中性色筛选采用简化方案：硬件只保留暗/饱和范围检查（`dark_min`、`sat_max`），删除增益乘法、min/max、比例乘法和 41 位比较流水。中性色保护交给固件。
2. 被删除功能的寄存器地址保留：地址仍可译码，读返回 0，写被忽略且不报 `pslverr`。旧固件和测试不会因访问非法地址而失败。
3. 四项改完后统一跑回归，不要中途跳过检查。

## 1. 开始前必须做

在服务器本地目录操作，不要通过 sshfs 挂载盘跑 `git` 或大批量打包（在挂载盘上这样做会超时）。

1. `git status` 记录当前改动。先提交或打 tag 保存现状，例如 `git tag pre-3a-cleanup`。
2. 备份涉及的目录：`rtl tests tools software/firmware`。
3. 先跑一遍当前回归，记录基线：`python tools/run_rtl_checks.py`、`python tools/test_video_3a.py`、`python tools/test_video_3a.py --full`、`python tools/test_camera_3a_runtime.py`、`python tools/test_qse.py`。基线失败的项单独记下，不算本次改动造成。

## 2. 现状（已读代码确认）

- 固件 3A 闭环已存在：`software/firmware/camera_3a.c`、`camera_ae.c`、`camera_awb.c`。读统计、算曝光和增益、写传感器和 APB 都在 CPU 上。这部分算法不改。
- 硬件统计：`rtl/isp/capture_frame_stats.sv`，在 `rtl/soc_integration/video_apb_ctrl.sv` 中例化为 `capture_statistics`。输出 12 个字的统计包（Y 累加、采样数、高光数、R/G/B 累加、有效 cell 数、总 cell 数、flags、帧号、配置号、source）。固件 `video_stats_read()` 解析这个包。**统计包格式不能改。**
- 顶层 `rtl/ti60f225_oob_top.v` 例化了 `luma_color_suppress`、`luma_tone_map`、`ae_frame_stats`（实例名 `display_meter`）和 `hdmi_info_overlay`（实例名 `information_overlay`）。
- `rtl/isp/sc431hai_auto_exposure.v`、`rtl/isp/auto_tone_lift.v`、`rtl/isp/hdmi_info_overlay_apb.v` 没有被顶层例化，只被测试台引用。

## 3. 步骤一：删除显示端直方图（HDMI 叠加）

RTL：

- 删除文件：`rtl/isp/hdmi_frame_histogram.v`、`rtl/isp/hdmi_info_overlay.v`、`rtl/isp/hdmi_info_overlay_apb.v`。
- `rtl/ti60f225_oob_top.v`：
  - 删除对应 `include`（第 24、25 行附近；`hdmi_info_overlay_apb` 如有也删）。
  - 删除 `information_overlay` 例化，让 `osd_vs/osd_hs/osd_de/osd_r/osd_g/osd_b` 直接由 `lift_vs/lift_hs/lift_de/lift_rdata/lift_gdata/lift_bdata` 赋值。
  - `video_display_hist` 线和 `video_apb_ctrl` 的 `.display_hist` 连接按步骤二处理。
- 文字 OSD 由 `osd_text_double_buffer` 绘制（overlay 的 `.i_text_enable` 已接 `1'b0`），不受影响。

行为变化：KEY0 之后只控制文字 OSD。`rtl/soc_integration/qse_ui_control.sv` 不引用 hist，应无需改。

测试：

- 删除 `tests/hdmi_overlay_tb.v`、`tests/hdmi_overlay_apb_tb.v`。
- `tools/run_rtl_checks.py` 中删除 `hdmi_overlay_tb`（三个调用）和 `hdmi_overlay_apb_tb` 的 `run(...)` 行。

## 4. 步骤二：删除采集侧 64 bin 直方图

`rtl/isp/capture_frame_stats.sv`：

- 删除端口：`hist_request`、`hist_valid`、`hist_data`、`hist_ready`。
- 删除信号和逻辑：`hist_mem`、`active_bank`、`frozen_bank`、`bin_valid`、`frozen_valid`、`hist_state`、`hist_q`、`freeze_q`、`stream_loaded`、`frozen_meta`、`hist_req_meta/sync`、`hist_seen`、`hist_pending`、`streaming`、`stream_index`、`pending_bin0/1`、`bin_value0/1`、`bin0/bin1`，以及 `hist_state` 的 `case` 块。
- `rgb_take` 分支只保留 `ys`、`samples`、`hot` 的累加，去掉 `if(hist_state!=0) cbad<=1; else hist_state<=1;`。
- `good&&hist_state==0` 改为 `good`。`rgb_end` 里去掉 `hist_pending&&!streaming` 整段。
- `rgb_start` 里去掉 `bin_valid<=0;hist_state<=0;`。
- 文件头注释 "AE/Y histogram" 改为 "AE Y sum"。

`rtl/soc_integration/video_apb_ctrl.sv`：

- 删除端口 `display_hist` 及 `assign display_hist=...`。
- 删除 `capture_statistics` 的 `.hist_request/.hist_valid/.hist_data/.hist_ready` 连接，以及 `histogram_mailbox`、`stream_*` 线、`hist_req`、`hist_cache`、`hist_cache_q`、`hist_meta`、`bin_index`、`meta_index`、`hist_busy/locked/fault/seq`、`expected_word`、`incoming_word`、对应的缓存 `always` 块、复位赋值、`if(stream_arrived)` 整段。
- `fault_sticky` 拼接里原来用 `hist_fault` 占一位，改为 `1'b0`，位位置不变。
- 寄存器保留地址（读 0，写忽略且不报错）：`0x100`、`0x104`、`0x108`、`0x10c`、`0x110`、`0x114`、`0x118`、`0x11c`、`0x120`、`0x124`、`0x128`、`0x12c`。这些地址设 `ext_writable=1`，写分支不做事，`value_error` 恒为 0。
- `disp_shadow[82:80]`（原 hist 控制位）不再使用，保留位宽，**不要移动 `[85:83]`（QSE UI）**。
- `0x038` CAPS 的 bit 6 清零：`32'h000001ff` 改为 `32'h000001bf`。`0x034` 版本改为 `32'h00020000`。

固件：

- `software/firmware/video_regs.h`：删除 `VIDEO_HIST_*` 宏、`video_hist_t` 和 `video_hist_poll` 声明。`VIDEO_REQUIRED_CAPS` 现为 `(1u<<3)|(1u<<5)|(1u<<8)`，不含 bit 6，保持不变。
- `software/firmware/video_stats.c`：删除 `video_hist_poll`。
- `software/firmware/main.c`：删除 `app_hist_enable`、`app_hist_updates`、`app_hist_errors`、`app_hist`、`video_hist_poll` 调用、`qse_hist_wanted`，以及所有对 `VIDEO_HIST_OSD` 的读写（约第 72、88、96 到 101、112、113、192 到 194 行）。KEY0 逻辑只设置文字 OSD。
- 检查 `video_ctrl.c`、`soc_video_driver.c` 里是否还有 hist 引用。

## 5. 步骤三：删除无用硬件 AE 和 auto lift，清空 display_meter 功能

- 删除文件：`rtl/isp/sc431hai_auto_exposure.v`、`rtl/isp/auto_tone_lift.v`。
- 删除测试：`tests/ae_controller_tb.v`、`ae_stability_tb.v`、`fixed_ae_tb.v`、`fixed_stability_tb.v`、`highlight_ae_tb.v`、`predictive_ae_tb.v`、`auto_lift_tb.v`。
- `tests/i2c_runtime_tb.v` 和 `tests/ae_camera_stats_tb.v` 在 `tools/run_rtl_checks.py` 里引用了 `sc431hai_auto_exposure.v`。先打开确认实际测什么：测硬件 AE 模块就删除；测 I²C 或统计本身，就去掉对该模块的依赖后保留。`ae_camera_stats_tb.v` 还依赖 `ae_frame_stats.v`，见下。
- `tools/run_rtl_checks.py`：删除对应 `run(...)` 行。
- `display_meter`（`ae_frame_stats`，量 lift 之后的亮度）：
  - 只被 `video_apb_ctrl` 的 `display_stats_mailbox` 使用，对应寄存器 `0x090`、`0x094`。
  - 先看 `tests/highlight_stats_tb.v` 和 `luma_lift_tb.v` 是否仍需要 `ae_frame_stats.v`。仍需要就保留文件，否则可一起删。
  - 顶层：删除 `display_meter` 例化和 `display_stats_valid`、`display_stats_mean` 线。`video_apb_ctrl` 的输入端口 `display_stats_valid`、`display_mean`、`display_strength`、`display_at_max` 删除，`tests/video_3a_tb.sv` 第 20 行附近同步修改。
  - `video_apb_ctrl`：删除 `display_stats_mailbox`、`display_stats_seq/value`。`0x090`、`0x094` 保留地址，读 0。
  - `effective_lift_strength` 仍被 `luma_tone_map` 使用，保留。

## 6. 步骤四：简化 AWB 硬件筛选

`rtl/isp/capture_frame_stats.sv`：

- 删除：`corr_r/g/b`、`color_max`、`color_min`、`neutral_lhs`、`neutral_rhs`、`neutral_enable`、`ratio`、`gr/gg/gb`，以及 `candidate` 里的中性比较。
- `candidate` 改为只用 `range_ok[3]`。可缩短 `awb_pipe_valid` 位数，但必须同步改 `awb_pipe_valid[3]` 的索引，保证 `pr/pg/pb/range_ok` 与 `awb_fetch` 对齐，并在仿真里确认 `cells` 计数不变。
- 端口 `gain_r/gain_g/gain_b`、`neutral_ratio` 删除。`awb_filter` 保留，只用 `[15:8]`（dark_min）和 `[23:16]`（sat_max）。
- `video_apb_ctrl.sv`：同步删除这些连接。寄存器 `0x190`、`0x194`、`0x198`、`0x19c` 保留，读写行为不变（`0x050` apply 的 `filter_valid` 校验仍要求 `cap_shadow[103:88]>=256`，固件不用改），只是硬件不再使用比例值和 `awb_filter[0]`。

固件补偿（替代硬件中性色筛选）：

- `software/firmware/camera_awb.c` 的 `camera_awb_target` 已有 `cells >= 5% total` 保护和 `smooth()` 限幅（单次最大变化 16，目标限制在 128 到 1024）。保持不变。
- 简化后进入累加的 cell 增多（含有色物体），灰世界估计会偏向场景主色。建议新增保护：R、B 目标与当前值之差连续超阈值时降低步长，或要求连续多帧同向才提交。参数先取保守值，并注明需上板调。**这是新增行为，要在 `tools/test_camera_3a_runtime.py` 的模型里加用例，不能只靠现有测试。**
- 如果固件补偿工作量过大，退回方案 (b)：保留硬件中性色筛选，只做步骤一到三。

测试：

- `tests/capture_equivalence_tb.sv`、`tests/capture_bram_backpressure_tb.sv`、`tests/video_3a_tb.sv`、`tests/ae_camera_stats_tb.v` 使用 `awb_filter` 和 `neutral_ratio`，且含参考模型。去掉参考模型里的中性色判断，端口同步，确认 1080p 全帧 `AE=32400`、`AWB=16200` 的计数仍成立。
- `video_3a_tb.sv` 里 `read('h128,...)`、`write('h128,8)` 等直方图检查删除，或改为 "读 0 且不报错"。

## 7. 联动文件（容易漏）

- `rtl/defines.v` 和 `tools/rtl_config_manifest.json` 由工具生成，带有被删模块的 `CFG_` 宏。**不要手改。** RTL 改完后运行 `tools/refresh_rtl_config.py`；若它处理不了已删文件，再看 `tools/centralize_rtl_config.py` 和 `tools/check_rtl_config.py` 的用法。
- 引用 hist 的脚本需逐个检查：`tools/package_qse_ui.py`、`generate_debug.py`、`remove_manual_debug.py`、`test_soc_cleanup.py`、`summarize_resource_optimization.py`、`plot_ddr_read_trace.py`、`test_camera_3a_runtime.py`。部分只是文档字符串或资源报表，逐个判断。
- `debug.json`、其生成源 `tools/generate_debug.py`、`debug_top.v`：VIO 有 `osd_hist_enable`、`osd_hist_mode`、`osd_hist_valid`、`osd_hist_samples` 四个探针。需用 Efinity 调试器向导重新生成，或手改后确认探针编号连续。
- Efinity 工程 `ti60f225_cam_hdmi.xml` 的源文件列表若含被删文件，要同步删除，否则综合报找不到文件。（我没有看过该 xml 的列表。）
- 文档：`software/firmware/README.md`、`QSE_UI.md`、`QSE_CHANGES.md` 中关于直方图、KEY0 控制直方图、统一统计的描述同步修改。

## 8. 统一回归

全部改完后依次执行，任一项失败先回到对应步骤定位，不要继续往下：

1. `python tools/refresh_rtl_config.py`，然后 `python tools/check_rtl_config.py`。
2. `python tools/run_rtl_checks.py`。
3. `python tools/test_video_3a.py` 和 `python tools/test_video_3a.py --full`。
4. `python tools/build_firmware.py`，然后 `python tools/test_camera_3a_runtime.py`。
5. `python tools/test_qse.py`。
6. Efinity：`efx_run ti60f225_cam_hdmi.xml --prj -f compile --output_dir <新目录>`，对比资源报告和改动前的 XLR 占用，再 `pgm` 生成 bit。**不要运行 `program`，除非单独授权烧板。**

通过判据：

- 所有仿真通过，测试数量等于 "基线数量减去被删除的测试"。
- `video_3a_tb` 打印的 AE、AWB 计数不变。
- Efinity 编译无新增时序违例，资源占用不高于基线。

## 9. 风险与未验证项

- 本方案只基于读代码，没有运行任何测试、固件编译或综合。
- 新版统一统计和软件 AE/AWB 本来就没有上板验证（`software/firmware/README.md` 写明）。删改之后仍需上板确认 AE 收敛、AWB 不偏色、HDMI 显示和 KEY0 行为。
- AWB 简化后的偏色风险只能靠上板调参确认，仿真覆盖不了真实场景。
- 编写本方案时 `.git` 状态未知：在挂载盘上跑 `git status` 超时，没有拿到结果，不知道当前是否有未提交改动。
