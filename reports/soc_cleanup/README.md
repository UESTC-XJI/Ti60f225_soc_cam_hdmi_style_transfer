# SoC遗留逻辑清理与文字使能修复

2026-10-09。用户授权按清单清理，并明确直方图参数已经在HDMI域、真正文字由osd_text_double_buffer负责，以及en2遗漏同步的问题。本轮涉及RTL，须使用本目录新生成的`soc_cleanup.bit`才能在实板生效。Efinity 2026.1 map/debug/interface/PNR/PGM全部PASS；PGM在此为本地生成bitstream，没有配置板卡或下载固件。配套ELF为本目录`soc_video_app.elf`，与`software/firmware/build/soc_video_app.elf`一致，保留上一轮AE调整。

## 源码变化

- 当前顶层移除sc431hai_auto_exposure、旧I²C主机及初始化链、旧AE统计/状态mailbox；CPU摄像头I²C直接连接开漏pad，旧所有权mux不再需要。
- 移除fixed_text_osd、display_status_mailbox、osd_status_mailbox及无消费者信号；osd_control_mailbox整体移除。hdmi_info_overlay直接读取HDMI域video_display_hist，文字输入固定关闭。
- auto_tone_lift被相同0～128手动强度限幅替代，tone/luma映射和display_meter保留。动态文字、启动彩条、统一APB/统计、共享DDR、复位屏障、故障保护和USER1/USER2调试分配保留。
- osd_text_double_buffer补齐en2<=en1，并经active_enable在VS上升沿生效。使能不需要COMMIT；字符页/位置/颜色仍按原COMMIT/ACK切换，关闭文字时提交仍然有效。
- 当前ti60f225_cam_hdmi.xml仅移除10项无效源文件：旧I²C族、旧owner mux和panel_config。历史源码文件与独立回归保留。板级引脚、接口XML、时钟约束和DDR参数不改。

## 验证记录

`tools/test_soc_cleanup.py`检查当前顶层/工程连接，实际顶层I²C pad和全部256档手动强度与旧模块等价。异步OSD仿真覆盖帧中开关、无COMMIT开关、关闭时COMMIT/ACK、活动页写保护及RGB透传。删除en2同步的反例准确复现旧故障。统一APB/真实Debayer、启动彩条/切换、帧率/故障统计、实际视频DMA与200次并发CPU共享DDR突发、完整RTL含两帧1920×1080、resize/DMA/CVO回归全部PASS。105份RTL/DDR/受保护内容与默认校准值审计PASS。

最终时序报告全部列出的setup/hold slack均为正：最小setup=0.260ns，hold=0.026ns；148.5MHz采集域setup=1.307ns，HDMI域5.268ns，100MHz core域3.344ns。详见timing.rpt、validation.json。综合资源相对software_3a：LUT4由31764降为31356（-408），FF由27676降为27668（-8），RAM/DSP不变。大部分旧逻辑原本已被优化，资源变化小于源码规模变化。

顶层从1394行减为1084行，活动项目移除10项旧源。构建输入XML另存build_project.xml；构建后仅恢复原XML排版，已验证完整语义一致。输出位于outflow_cleanup，验证后归档到本目录；旧release未覆盖。文件和相关源码SHA256见manifest.json。

## 实板使用

停止IDE调试，重新打开清理后的ti60f225_cam_hdmi.xml以刷新源文件列表；使用Efinity Programmer在JTAG模式配置本目录soc_cleanup.bit。释放Programmer连接，再用soc_video_app_ti加载本目录或build目录最新ELF，F8运行。检查RAW/RESIZE约30、DISP60、DROP/ERR0、AE/AWB更新正常；通过APB 0xF8100004 bit0测试文字开关，无需额外COMMIT，变化在同步后的帧边界生效。文字关闭期间COMMIT仍应切页并返回ACK。

实际显示开关效果尚未实板确认。此前bit和固件发布目录保留，本轮没有调整AE/AWB算法。
