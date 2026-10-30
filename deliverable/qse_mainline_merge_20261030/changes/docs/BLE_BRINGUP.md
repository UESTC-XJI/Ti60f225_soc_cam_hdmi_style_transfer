> 2026-10-30 外设合并更新：以下历史产物哈希仅用于旧版记录；当前接线/命令请以 `QSE_MAINLINE_MERGE.md` 为准。KEY0=GPIOL_11，KEY1=GPIOL_09；原 GPIOR_22 控制已移除；快照仅 320×240。

# BLE 图传上板 Bring-up（2026-10-29 定稿）

> 适用产物：位流 `ti60f225_oob.bit` md5 `8ed79a95…`（AE 修复版）
> 固件 `soc_video_app.elf` md5 `e33708e9…`（快照 XOR 修复 + 星空 v2 `sn_dc` 权重）
> 本文件只讲"怎么连、怎么验、坑在哪"。协议细节见 `BLE_SNAPSHOT.md`，权重约定见 §5。

---

## 1. 硬件接线

| 功能 | 顶层端口 | 引脚 | 方向 |
|---|---|---|---|
| BLE RX（模块→FPGA） | `system_uart_0_io_rxd` | **GPIOL_06** (C3) | input，weak pullup |
| BLE TX（FPGA→模块） | `system_uart_0_io_txd` | **GPIOR_13** (A12) | output |
| 旋钮 SW1/SW2 | `io_sw1/io_sw2` | GPIOL_04 / GPIOL_10 | input |
| KEY0（FPS 开关） | `io_key0` | GPIOL_11 | input，高有效，弱下拉 |
| KEY1（视图切换） | `io_key1` | GPIOL_09 | input，高有效，弱下拉 |

- 模块：**JDY-3x**（BLE 串口透传，服务 FFE0/FFE1），3.3 V，**128000 8N1**。
- **TX/RX 必须交叉**：FPGA TX(GPIOR_13) → 模块 RX；模块 TX → FPGA RX(GPIOL_06)。
  若收不到任何字节，先把 `ti60f225_oob.peri.xml` 里这两行的 `gpio_def` 对调再试。
- 本 build **复用 UART0**，调试串口被编译掉：插上后 COM 口无日志是正常的。

## 2. 连接方式（Web Bluetooth）

**推荐：本机 Chrome/Edge + localhost**

```bash
cd _incoming/starry30_q
python -m http.server 8000 --bind 127.0.0.1 --directory tools/ble_web
# 浏览器打开 http://127.0.0.1:8000/
```

点"连接"→ 弹窗里选 `JDY-…`。页面用 `acceptAllDevices: true` + `optionalServices`，
不依赖 name/UUID 过滤；连上后自动识别 FFE0/FFF0/NUS。

**不要**：
- 在 Windows「设置 → 蓝牙」里点"配对"——BLE 串口模块不配对，配上反而占死 GATT；
- 用 `file://` 直接双击打开（部分 Chrome 版本拒掉 Web Bluetooth）。

## 3. 标准验收流程

1. 连上后先发 `STATE`，应回六行：KNOB / SLOT / BANK / OSD / VIEW / RATE。
2. 发 `SNAP,320,50`（用时取决于 JPEG 大小和 RATE）：
   - 回包 `IMG,320,240,<bytes>,<crc32>,<packets>`，crc32 必须对；
   - 最后必须收到 `IMG,END`；
   - 判图两条硬标准：**灰阶/纯色区 R=G=B**；**不应出现每 128 灰阶跳一档的色带**。
3. 通过后再发 `SNAP,320,60` 看全图。
4. HDMI 主链路同时看：FPS 叠加、旋钮 G1–G4 切换。

## 4. 已知坑（按踩坑顺序）

| 现象 | 原因 / 处理 |
|---|---|
| 手机/电脑搜得到但连不上 | ①模块被上一个中心占着（JDY 单连接）→ 拔模块 VCC 重上；②系统蓝牙里配对过 → 删掉；③`file://` 打开 → 用 localhost |
| 连上但发 `STATE` 没回复 | 模块波特率不是 128000（JDY 出厂多为 9600），先改模块波特率 |
| 图能收但颜色发花 | **快照漏了 XOR**，见 §5；不是链路问题 |
| 传输中断/重传多 | 默认限速 1500 B/s 是保守值，`RATE,<n>` 可调到 12800；丢字节就调低一档 |
| 掉电后 BLE 没了 | 位流/固件都是易失的，掉电回 SPI flash 旧版，需重烧 |

## 5. 快照像素契约（本工程的坑，务必遵守）

风格结果槽 `raw_base(slot) + 0x800000` 里存的是：

```
DDR 值 = 屏幕 RGB ^ 0x808080     （每通道最高位翻转）
```

- 写侧：`style_network` 经 `style_axi_rows` 写入时 `wr_pixel ^ 0x808080`；
- 显示侧：`style_axi_rows` **读回不 XOR**，由 `style_display.sv` 统一 XOR 一次；
- **任何直接读 DDR 的消费者（BLE 快照 / 调试 dump / 未来的 OSD 合成）必须自己 XOR 一次。**

⚠ 与 `Ti60f225_soc_cam_hdmi_style_transfer-worktree-auto-resume-fw` 不同：那边
`style_axi_rows` 读回时 XOR、显示再 XOR（抵消），所以那边直接读 DDR 就是屏上值。
**两套工程的 DDR 契约不同**，复制代码时最容易在这里翻车（10-29 快照发花就是这个）。

## 6. 回滚

| 目标 | 件 | md5 |
|---|---|---|
| 回旧星空权重 | `backup/weights_rollback_20261029/rowpipe_weights_old_b995616f.h` 重编 | XOR `0xb995616f` |
| 彻底回无 BLE | 10-28 完整包 `deliverable/starry30_q_20261028` | bit `350eb510…` + ELF `eae55f8b…` |
