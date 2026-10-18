# 显示紧急读通道保留

2026-10-12，基于实板闪烁诊断继续修复。实板正常并发负载约 14～15 NN fps 时，每秒约 3458 个显示欠载上升沿，FAULT=4，CSI/DMA/AXI/推理错误为 0。暂停采集和新推理、保留原显示后欠载停止；恢复负载后重新增长。

## 实现

内层 `axi_shared_ddr_2m` 新增默认关闭的 `URGENT_OVERRIDES_FAIRNESS` 和 `RESERVE_URGENT_READ` 参数，实际 style 系统动态仲裁同时开启。紧急显示请求可以覆盖 CNN 三次绕过上限，并在显示 reader 拆包、下一次 AR 尚未提出的间隙禁止接受新的 CNN AR。已经在途的事务正常完成，不中途取消或抢占。

仅取消三次上限无法覆盖 inter-burst gap：显示 reader 此时 ARVALID=0，CNN 在空闲边界获得通道，即使显示很快再次提出紧急 AR，也必须等待 CNN 突发结束。保留通道针对这个空隙。

显示 urgent 条件增加“当前行任务进行中或请求排队”的限定，避免垂直空白时像素 FIFO 空导致 CNN 永久禁止；低水位从 256 改为 384，增加允许新 CNN 读之前的数据余量。非紧急时仍遵守原有 round-robin/计数逻辑。外层 CPU/video 桥参数保持默认，不启用新策略。

此策略优先保显示实时性，NN 吞吐可能下降，必须上板测量。没有新增行缓存、修改网络/权重或隐藏欠载计数；当前版本仍会读取同 epoch 中过期的行，该恢复策略另行评估。

## 已完成验证

`tools/test_style_display_deadline.py`：显示 urgent、CNN 持续请求时连续至少 80 次显示授权；显示暂未提出 AR 的 20 周期空隙没有插入 CNN；解除 urgent 后公平仲裁，完整 ID 路由及 180 次读完成。

原 DDR beat/FIFO/profiler/三次公平单测、两级共享桥 ID/数据回归通过。原显示测试保留故意 50 us 返回停顿：三帧正确恢复、欠载保持可见并输出黑色，不以更改测试隐藏物理 DDR 停顿。

`tools/test_style_display_contention.py`：真实显示 reader/FIFO/仲裁器、一整帧 720p 时序、持续 CNN 32-beat 请求、模拟 CNN 首 beat 延迟 320 个 100 MHz 周期、显示首 beat 延迟 24 周期及随机 beat 间隙。没有物理 DDR、外层 CPU 或抓帧写流。

| 策略 | 正确像素 | 欠载像素 |
| --- | ---: | ---: |
| 原三次上限 | 896 | 613504 |
| 仅允许 urgent 覆盖上限 | 896 | 613504 |
| urgent 覆盖＋拆包间隙通道保留 | 614400 | 0 |

这些数值是压力刺激下的像素数，不能与实板 UF 上升沿次数直接比较。压力 test 明确要求旧版复现欠载、新策略无欠载，并核对所有有效输出的左右 RGB 和同步时序。

构建/集成仿真目录：`reports/style_demo/display_deadline/`、`reports/style_demo/ddr_optimization/adaptive_reserve/`。最终编译目录 `outflow_style_deadline_reserve/`。

## 实板结果

新版本已烧录并下载配套诊断ELF。用户确认“已不再闪烁”。约92.688秒稳定窗口内UF增加16次（0.173次/秒），原诊断版约3458次/秒；CSI/DMA/AXI/推理错误保持0。NN约9～10 fps，低于原版约14～15 fps。仍存在少量偶发欠载，不宣称绝对零欠载。最终CPU已resume，JTAG和串口已释放。

完整记录：`reports/style_demo/release_display_deadline/hardware/README.md`。配套bit/ELF和编译、源文件校验值见同一发布目录的manifest。
