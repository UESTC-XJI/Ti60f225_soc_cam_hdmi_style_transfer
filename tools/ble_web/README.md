# 蓝牙图传浏览器应用

把 HDMI 上当前显示的**风格迁移结果**（原生 320×240）拍成 JPEG，通过 BLE 透传模块传到浏览器。
桌面页和手机页共用一套逻辑，支持四风格 × 五档、PWA 安装与离线打开。

## 页面

| 文件 | 用途 |
|---|---|
| `index.html` | 桌面两栏控制台 |
| `index_mobile.html` | 手机单列布局，档位区置顶、触控加大 |
| `app.js` / `app.css` | 两页共用的逻辑与设计系统 |
| `ble_proto.js` | 图传协议（浏览器侧） |
| `sw.js` | Service Worker，离线缓存页面和图标 |
| `manifest*.webmanifest` | PWA 清单（桌面 / 手机各一份） |
| `icons/` | 192/512/maskable/apple-touch 图标 |

风格与档位：G1 starry / G2 candy / G3 mosaic / G4 feathers，每个风格 5 档，
网页统一显示 **10% / 30% / 50% / 70% / 100%**，默认第 3 档（50%）。

## 使用

- **本机（最简单，不需要任何服务器）**：用 Chrome / Edge 直接双击打开 `index.html`。
  `file://` 属于安全上下文，蓝牙和拍摄都正常；只是不能注册 Service Worker，
  所以没有离线缓存和“安装”按钮。

- **手机 / 另一台电脑，同一 Wi-Fi**（不需要 ZeroTier）：
  1. 电脑运行 `ipconfig`，找到 WLAN 的 IPv4 地址，例如 `192.168.1.23`；
  2. 在项目根目录运行：
     ```
     python tools/ble_web/serve.py --bind 192.168.1.23 --port 8443 --https
     ```
     首次运行会在 `tools/ble_web/cert/` 生成自签证书（不进 git）；
     Windows 防火墙弹窗选“允许访问”；
  3. 手机 Chrome 打开 `https://192.168.1.23:8443/`，证书警告点“高级 → 继续前往”。

  如果同一 Wi-Fi 打不开（校园网 / 公共 Wi-Fi 经常隔离设备），改成**手机开热点、电脑连热点**，
  再用 `ipconfig` 查到的新地址重复第 2–3 步即可。
  蓝牙连接始终发生在**打开网页的那台设备**和板子的 BLE 模块之间；电脑只负责发网页。

- **手机和电脑不在同一网络（可选）**：ZeroTier 只是这种情况下的虚拟组网工具，不是必需。
  装好并加入同一网络后，`serve.py` 不带 `--bind` 会自动监听 ZeroTier 地址。
  也可以继续用 `--bind <ZeroTier IP> --https` 手动指定。

- **PWA（安装成 App 图标）**：需要受信任的 HTTPS 或 localhost。电脑本地验证：
  ```
  python tools/ble_web/serve.py --bind 127.0.0.1 --port 8000
  # 打开 http://127.0.0.1:8000/ ，Chrome 地址栏会出现安装图标
  ```
  装好后独立窗口全屏运行，页面已预缓存，断网也能打开。
  手机端使用自签证书时 Chrome 通常不给安装按钮，直接在浏览器里用即可，不影响蓝牙。
  iPhone 上的任何浏览器都不支持 Web Bluetooth。

- **不推荐**：把 html 直接发到手机用 `file://` 打开；安卓 Chrome 下蓝牙权限和安装都不可靠。

不支持：Firefox、Safari、iPhone 上的任何浏览器。

## 协议

见 `software/firmware/qse_imgtx.h`。浏览器发 `SNAP,<w>,<q>,<win>`（`w` 仅支持 320），板子暂停
CNN 流，读当前显示槽位的风格结果，编码 JPEG，按 128 字节分包发送；浏览器按序 `ACK`，
丢包或 CRC 错误回 `NAK` 让板子从该包重发。其它文本行由板子原样回显。

快捷指令（`software/firmware/qse_ble.h`）：

- `VIEW`、`OSD` 切换（或 `VIEW,0/1`、`OSD,0/1` 直接设置）；
- `KNOB,0..3` 选旋钮档位（下一次拨动实体旋钮前有效）；原始编码不连续：
  `0=G3 马赛克、1=G1 星空、2=G2 糖果、3=G4 羽毛`；
- `SLOT,0..3` 切换 active 风格（starry / candy / mosaic / feathers）；
- `TIER,<style 0..3>,<tier 0..4>` 设置该风格强度；
- `RATE,<B/s>` 设置板卡发送速率；`STATE` 查询 KNOB/SLOT/TIER/OSD/VIEW/RATE。

板卡输出按 `RATE` 限速（默认 1500 B/s）。BLE 模块没有流控，按 UART 满速写入会溢出模块缓冲
并丢字节。网页连接后会自动下发页面上选的速率；重传多就调低一档，稳定后可以逐档调高找上限。

## 测试

```
python tools/test_qse_mainline.py          # 实际 RV32 ELF 的外设/图传回归
node tools/ble_web/test_mainline_ui.js    # 网页状态、SLOT/TIER 写入、PWA 接线、真实图传回放
node tools/ble_web/test_ble_proto.js      # 板卡字节流回放：重复包、丢包、坏包恢复
python tools/ble_web/gen_icons.py         # 重新生成 PWA 图标（需要 Pillow + numpy）
```

本次外设合并的引脚、命令和构建说明见 docs/QSE_MAINLINE_MERGE.md。
