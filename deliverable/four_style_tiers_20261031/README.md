# 四风格 × 5 档 + 旋钮/BLE 同步调档（2026-10-31 最终版）

## 最终映射

| 旋钮 | 风格（style 编号） | 5 档（默认第 3 档） |
|---|---|---|
| G1（raw 01） | **starry 星空**（0） | sw5 / sw10 / **sw15** / sw20 / sw25 |
| G2（raw 10） | **candy 糖果**（1） | sw1.5 / sw2 / **sw2.5** / sw3 / sw4 |
| G3（raw 00） | **mosaic 马赛克**（2） | l1200 / l200 / **t025** / t05 / t1 |
| G4（raw 11） | **feathers 羽毛**（3） | sw1 / sw3 / **sw3.5** / sw4 / sw5 |

- 四个风格各 5 档，共 20 个权重；默认均为第 3 档（中间档）。
- 旋钮和 BLE `SLOT/TIER` 驱动同一个 active 风格/档位；网页会回读同步。
- 每个风格独立记住自己的档位。
- **网页显示统一为 10% / 30% / 50% / 70% / 100%**（第 3 档=50% 默认）；
  底层权重仍是上表里的 SW/tier 名。

## DC

- starry / candy / feathers 的 15 个档已在生成 board header 时按各自
  `style_meta.json` 的 `dc_target_q_suggest` 叠到 L11 bias：
  `Δbias = Δq × 2^shift / M`，并用 t025 原始 blob 对拍验证了公式。
- mosaic 5 档沿用 rowpipe_keys 里已做 DC 的 board header（DC [0,0,0]）。
- 末层 Q beat 全部为 `(shift,129,127)`（有符号，无 ReLU）。

## 存储 / 资源

- 20 个 blob × 14,448 B ≈ 289 KB，全部放在固件 `.rodata`（DDR app 区）。
- `software/firmware/app.ld` 的 `LENGTH = 4M`（原 124K）；只把当前档搬到引擎
  `0x06F00000`。**不改 RTL、不重新 PnR，XLR 不变。**
- 位流仍是 `06d3ad8a…`（启动动画 + BRAM 字模 FPS + 采集/显示）。

## 产物

| 文件 | md5 |
|---|---|
| `ti60f225_oob.bit` | `06d3ad8aed317e6162c1b87febc1d375` |
| `soc_video_app.bin` | `d90d0fbd6b5ed0d90e524687b16662bd`（313,048 B） |
| `soc_video_app.elf` | `f2f8ad0bf739b8099ff8ffdeffab4704` |

## 实板验证（2026-10-31）

- 上电旋钮在 G2：`style_active_bank_index=1`（candy），
  `style_tier_index={2,2,2,2}`，`app_style_switches=1`（上电选风格）。
- 引擎权重窗口首字 `0x513fe419`，与 **candy_sw2p5（tier2，带 DC）** header 完全一致。
- 实拍 `captures/candy_default.png`：右半屏糖果风格、左上 FPS31、对比模式正常。

## BLE / 网页

- 命令：`SLOT,<0..3>` 切风格；`TIER,<0..3>,<0..4>` 调档；`TIER?` 查询；
  `STATE` 同时回 `SLOT/BANK/TIER`。
- 桌面网页：`C:/Users/zhaojiaxuan/Desktop/index.html`，
  手机网页：`C:/Users/zhaojiaxuan/Desktop/index_mobile.html`
  （`app.js` / `app.css` / `ble_proto.js` 同目录）。
  - 四风格色卡 + 10%/30%/50%/70%/100% 分段按钮，每风格独立记忆档位；
    手机页单列布局、档位区置顶、触控尺寸加大。
  - PWA：`manifest*.webmanifest` + `sw.js` + `icons/`；HTTPS 或 localhost 下可
    “安装”到桌面、独立窗口运行并离线打开。
  - 本包 `web/` 含全部网页文件（页面、CSS/JS、PWA 清单与图标）副本。
  - iOS Safari 不支持 Web Bluetooth；Android 用 Chrome/Edge。

## 上板

```bash
# 位流（若板子重启过）
G:/Efinity/2026.1/bin/efx_run.bat ti60f225_cam_hdmi.xml -f program --pgm_opts mode=jtag
# 固件（OpenOCD；路径不要带空格）
openocd.exe -f software/firmware/openocd/soc_video.cfg \
  -c "reset halt" \
  -c "load_image soc_video_app.bin 0x1000 bin" \
  -c "reg pc 0x1000" -c "resume" -c "shutdown"
```

## 文件

- `changes/software/firmware/`：style_driver、20 个 board header、style_banks_final、
  qse_ble、main、app.ld。
- `changes/` 也可在完整工程 `F:/fm_qse_int_1031/` 中找到；构建用该工程。

## 扩展

新增风格/档位只需加 board header + `style_banks_final.h` include +
`style_driver.c` 表项；70 档约 1.1 MB，仍小于 4M；存储只在 DDR，不占 XLR。
