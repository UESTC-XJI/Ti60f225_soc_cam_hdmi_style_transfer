# mosaic 5 档强度 + 蓝牙网页调档（2026-10-31，待上板验证）

## 状态

- 位流**不变**：沿用 `06d3ad8a…`（启动动画 + BRAM FPS + 采集/显示）。
- 固件新增 mosaic 5 档权重和 BLE/网页调档；**未改 RTL、未重新 PnR**，XLR 不变。
- 权重放在固件 `.rodata`（DDR app 区），只把当前选中的一档搬到引擎权重窗口
  `0x06F00000`。`software/firmware/app.ld` 的 `LENGTH` 从 **124K 改为 4M**：
  20 档约 290 KB，70 档约 1.1 MB，4 MB 仍有富余。
- **已上板验证**：默认 tier2/t025；网页实际调档 8 次、错误 0；
  当前 tier0 时引擎权重窗口首字 `0x7f370ef8` 与 l1200 数组完全一致。

## mosaic 5 档

顺序按纹理强弱，第三档 t025 为默认/效果最好：

| 档位（网页） | bank 内 tier | artifact | XOR |
|---|---:|---|---|
| 1 l1200 | 0 | mosaic_glass_l1200_20261031_2107 | 0x05f94bc2 |
| 2 l200 | 1 | mosaic_glass_l200_20261030_1614 | 0x8a7f92c1 |
| **3 t025（默认）** | **2** | mosaic_glass_t025_20261031_1650 | 0x9da15c61 |
| 4 t05 | 3 | mosaic_glass_t05_20261031_1507 | 0x209af13e |
| 5 t1 | 4 | mosaic_glass_t1_20261031_1412 | 0xc4c0e40c |

其它风格（starry_old / starry_v7 / starry_v8 / rainbow）暂为**单档**；
风格选择仍走 bank/SLOT。

## BLE 协议新增

| 命令 | 作用 |
|---|---|
| `TIER?` | 回 `TIER,<bank>,<tier>,<count>,<name>` |
| `TIER,<bank>,<tier>` | 设置某 bank 的档位；mosaic 是 bank3，tier 0..4 |
| `SLOT,<bank>` | 切风格；响应里带 `TIER` |
| `STATE` | 原状态 + `TIER` |

当前 bank 已是目标 bank 时，`TIER` 会走与切风格相同的停流/写权重/XOR 校验/放行；
非当前 bank 只记住档位，等切过去时生效。切风格/调档后 `SLOT`/`BANK`/`TIER` 都会回传。

## 网页

桌面版已改：`C:/Users/zhaojiaxuan/Desktop/index.html`（并把 `ble_proto.js` 补到同目录）。

新增“风格强度（mosaic 5 档）”：
- 风格下拉：starry_old / starry_v7 / starry_v8 / **mosaic** / rainbow；
- mosaic 时可点 1..5 档；默认第 3 档 t025；
- 连接后自动 `STATE` 同步；调档发 `TIER,3,<0..4>`；
- 其他风格档位按钮禁用（单档）。

本目录 `web/` 是同一份网页和 `ble_proto.js`。

## 产物

| 文件 | md5 |
|---|---|
| `ti60f225_oob.bit` | `06d3ad8aed317e6162c1b87febc1d375`（与通过验证的动画+FPS版相同） |
| `soc_video_app.bin` | `08392d1b5a92d54d3e66b273e30af38a`（153,832 B，含 l1200 档） |
| `soc_video_app.elf` | `4feba8713c04ea8ac7a88b60d037b5f0` |

固件必须和 `06d3ad8a…` 位流配套。

## 上板步骤（待板子在线）

```bash
# 位流已经验证过；若板子重启过，先重烧 06d3ad8a…
G:/Efinity/2026.1/bin/efx_run.bat ti60f225_cam_hdmi.xml -f program --pgm_opts mode=jtag

# 新固件（OpenOCD；路径不要带空格）
openocd.exe -f software/firmware/openocd/soc_video.cfg \
  -c "reset halt" \
  -c "load_image soc_video_app.bin 0x1000 bin" \
  -c "reg pc 0x1000" -c "resume" -c "shutdown"
```

验证顺序：
1. 旋钮拨 G2（bank3）→ 默认第 3 档 t025；`STATE`/`TIER?` 应回 `TIER,3,2,5,mosaic_t025`；
2. 打开 `index.html` → 连接蓝牙 → 在“风格强度”点 1..5，画面纹理应逐档变化；
3. 切到其他风格再切回 mosaic，应保留上次档位（非当前 bank 的档位只记忆）。

## 静态检查（已做）

- `style_tier_index` 初值 `{0,0,0,2,0}`（bank3 默认 tier2）；
- 5 个 mosaic 数组都在 `.rodata`，XOR/符号齐全；
- 网页内联 JS 通过 `node --check`。

## 扩展到 4×5 / 70 档

- 每个新档/新风格只需：加 board header + 在 `style_banks.h` include +
  在 `style_driver.c` 的 tier 表加一行 + 必要时加 count；
- 存储只是 `.rodata`/DDR，不改 RTL，不占 XLR；
- 70 档约 1.1 MB，仍在 `app.ld` 的 4M 内；若再大改一行 `LENGTH` 即可。
