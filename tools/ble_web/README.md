# 蓝牙图传浏览器应用

把 HDMI 上当前显示的**风格迁移结果**（640×480）拍成 JPEG，通过 BLE 透传模块传到浏览器。

## 使用

- **本机**：用 Chrome / Edge 直接双击打开 `index.html`（`file://` 属于安全上下文）。
- **安卓 Chrome / 其他电脑（ZeroTier）**：在本机运行
  ```
  python3 tools/ble_web/serve.py            # http://<ZeroTier IP>:8443/
  ```
  只监听 ZeroTier 地址，只提供 `index.html` 和 `ble_proto.js`。
  远程浏览器默认不允许 HTTP 页面使用蓝牙，二选一：
  1. 远程 Chrome 打开 `chrome://flags/#unsafely-treat-insecure-origin-as-secure`，填入 `http://<ZeroTier IP>:8443`，Enabled 后重启；
  2. `serve.py --https`，自签证书放在 `tools/ble_web/cert/`（不进 git），远程设备需信任或手动放行证书。

  蓝牙连接始终发生在**打开网页的那台设备**和板子的 BLE 模块之间；ZeroTier 只用来下载网页。

不支持：Firefox、Safari、iPhone 上的任何浏览器。

## 协议

见 `software/firmware/qse_imgtx.h`。浏览器发 `SNAP,<w>,<q>,<win>`，板子暂停 CNN 流，
读当前显示槽位的风格结果，缩放到 w×(3w/4)，编码 JPEG，按 128 字节分包发送；
浏览器按序 `ACK`，丢包或 CRC 错误回 `NAK` 让板子从该包重发。其它文本行由板子原样回显。

快捷指令（`software/firmware/qse_ble.h`）：`VIEW`、`OSD` 切换（或 `VIEW,0/1`、`OSD,0/1` 直接设置），
`KNOB,0..3` 选档位（下一次拨动实体旋钮前有效），`RATE,<B/s>` 设置板卡发送速率，`STATE` 查询全部状态。

板卡输出按 `RATE` 限速（默认 1500 B/s）。BLE 模块没有流控，按 UART 满速写入会溢出模块缓冲并丢字节。
网页连接后会自动下发页面上选的速率；重传多就调低一档，稳定后可以逐档调高找上限。

## 测试

```
python3 tools/test_firmware_runtime.py     # img_snap 场景：固件完整走一遍并写出 reports/simulation/img_snap*.{jpg,bin}
node tools/ble_web/test_ble_proto.js       # 用上面的字节流回放浏览器接收端（丢包、坏包、穿插事件行）
```
