# 统一 APB / 采集统计 / 软件 AE / AWB 配套产物

2026-10-08；基于提交 `5d9d86e338cc84b92c432a5dc7f8b656ac73d654` 的未提交实现。**本版本未烧录或实板验证。** 新硬件/固件必须配套；默认软件 AE 和 AWB 自动，VTS/PLL不变。烧录步骤见工程根目录 README_PROGRAMMING.md，具体实现见 docs/VIDEO_3A_IMPLEMENTATION.md。

| 文件 | 字节数 | SHA256 |
|---|---:|---|
| `software_3a.bit` | 3,064,377 | `F2BBDC0A73C9979784AF07BEB0113B783705777A44B40F1E4DA34A7C30FA0F9F` |
| `soc_video_app.elf` | 131,992 | `9231F57B87E4B81984AB4272E87CF7F23AFF352CC02F8B0171AEE6A4C40AC7F6` |
| `soc_video_app.bin` | 10,512 | `97CCD8777477329E886026EF5BE762693BA3ABEF7CB44F6B6D6480045A32B1A0` |

## 编译和时序

Efinity 2026.1 map/debug/interface/PNR/PGM PASS（PGM在此为生成bitstream，未访问板卡）。最终setup最小裕量=0.397ns，hold最小裕量=0.026ns；148.5MHz采集域setup=1.537ns，74.25MHz HDMI setup=5.580ns，100MHz core setup=3.321ns。详见 compile.log / timing.rpt。

基础综合资源（resources.rpt，不混同debug插入后的利用率）：LUT4=31764，FF=27676，ADD=4062，DSP48=17，DSP24=2，SRL8=1210，RAM10=142，DPRAM10=4。新增统计/冻结缓存及动态绘图消耗较多逻辑，未承诺比旧版本节省总资源。

固件 text=10508、data=4、BSS=488；入口0x1000，仍在既定DDR程序/栈窗口内。BIN不是Flash启动镜像。已保存ELF/BIN/MAP与源文件/产物哈希 manifest.json。

## 验证

- capture.log：异步core/采集/显示时钟，真实gain/Debayer，旧APB兼容和扩展访问保护，RAW/RGB同帧/版本、影子锁定和帧边界ACK，64bin与冻结META，neutral比例端点/无候选，尺寸/故障、backpressure/overrun、序号回绕和中途复位，以及新RAW帧头覆盖旧RGB帧尾的短VS重叠。
- full_capture.log：两张完整1920×1080帧，每帧32400个AE样本、16200个AWB单元，独立像素参考校验Y和/高光及全部64bin，gain配置版本与提交。
- runtime.log / camera_3a_runtime.json：真实RV32 ELF的控制函数和完整_start/main；独立曝光响应模型收敛、两份绿色的绝对AWB增益、提交/曝光等待协调，固定/锁定、零分母/不足样本，高光保护，NACK/timeout/missing ACK VALID/START或STOP dropped/保留字段/写入不保留的读回失败、释放Hold、无统计/旧CFG/撕裂/回绕，非阻塞hist读取预算与bin和检查。
- boot.log / firmware_runtime.json：完整ELF启动、GP/SP/BSS、UART、DDR、摄像头ID重试、OSD无ACK、低32位timer回绕和trap。
- rtl_regression.log：原有HDMI overlay、tone/lift、mailbox、AE、I²C以及完整Debayer统计回归全部通过。
- resize.log：独立面积缩放参考（含1080p→720p）、CSI gearbox/Debayer/resize两张完整帧、错误尺寸/overflow/reset、DMA背压/4KiB边界和720p输出时序通过。
- 同会话还通过启动彩条、RAW/RESIZE/DISP诊断、shared DDR+真实DMA+200次并发CPU突发、受保护RTL/DDR默认值审计、IDE/OpenOCD仅配置解析及git diff --check。

Icarus提示的constant-select、既有RAM表达式和旧DMA端口位宽警告不代表新功能失败。受保护Sapphire CPU不能直接做Icarus物理系统仿真：指令模型不涵盖cache、真实MIPI/DDR/I²C电气时序，灰/白卡与光源测试仍须实板完成；本次未确认12FPS原因。

## 使用与观测

配套下载本目录 bit/ELF 后，UART应出现 `Software AE/AWB enabled`（需实际VTS/ID/I²C通过），并每秒输出 `3A state ... exp ... vts ... mean ... hot ... R ... B ... err ...`。IDE查看 `app_3a`；`app_awb_mode`=0固定校准、1自动、2锁定。`app_hist_enable` 默认0，设1可非阻塞获取完整快照，查看 `app_hist` 的bins/meta以及 `app_hist_updates/app_hist_errors`。

保留启动彩条、VIDEO_READY、OSD页协议和RAW/RESIZE/DISP诊断；旧ELF可以使用新硬件的兼容寄存器，新ELF应配套本版硬件。旧reports/raw_resize和startup_colorbar产物保留。
