# 四风格 × 5 档强度 + 旋钮/BLE 调档（2026-10-31 最终版）

## 最终映射

| 旋钮 | 风格（style） | 5 档（默认第 3 档） |
|---|---|---|
| G1 raw01 | starry 星空（0） | sw5 / sw10 / **sw15** / sw20 / sw25 |
| G2 raw10 | candy 糖果（1） | sw1.5 / sw2 / **sw2.5** / sw3 / sw4 |
| G3 raw00 | mosaic 马赛克（2） | l1200 / l200 / **t025** / t05 / t1 |
| G4 raw11 | feathers 羽毛（3） | sw1 / sw3 / **sw3.5** / sw4 / sw5 |

- 每风格 5 档、默认中间档；每风格独立记住自己的档位。
- 旋钮和 BLE `SLOT/TIER` 驱动同一 active 风格；网页回读同步。
- **网页统一显示 10%/30%/50%/70%/100%**，第 3 档=50%；底层权重仍是表里的 SW/tier。
- 旧的 rainbow、starry_v7/v8 不再出现在最终 4 风格表中。

## DC

- starry / candy / feathers 的 15 个档按各自 `style_meta.json` 的
  `dc_target_q_suggest` 写入 L11 bias：`Δbias = Δq × 2^shift / M`；
  公式已用 mosaic t025 原始 blob 与其 board header 对拍。
- mosaic 5 档沿用 rowpipe_keys 已做 DC 的 board header（[0,0,0]）。
- 末层 Q beat = (shift,129,127)（有符号、无 ReLU）。

## 存储与资源

- 20 × 14,448 B ≈ 289 KB，全部在固件 `.rodata`（DDR app 区）。
- `software/firmware/app.ld`：`LENGTH = 4M`（原 124K）；运行时只把当前档
  搬到引擎窗口 `0x06F00000`。
- 不改 RTL、不重新 PnR；位流仍是 `06d3ad8a…`，XLR 不变。

## 固件/网页

- `style_driver.c`：`style_defs[4]` + 每风格 `tiers[5]`、`style_tier_index[4]`
  （初值 `{2,2,2,2}`）、`style_set_tier()`。
- `qse_ble.c`：`TIER?`、`TIER,<style>,<tier>`；`SLOT`/`STATE` 回 `TIER`。
- 网页：桌面 `C:/Users/zhaojiaxuan/Desktop/index.html`、手机
  `C:/Users/zhaojiaxuan/Desktop/index_mobile.html`；四风格色卡 + 10/30/50/70/100%
  分段按钮，每风格独立记忆档位；`app.js` / `app.css` / `ble_proto.js` 同目录。
  PWA：`manifest*.webmanifest` + `sw.js` + `icons/`，HTTPS/localhost 下可安装、
  离线打开；`serve.py` 已能提供这些文件。手机页单列、档位区置顶、触控加大。
- 旋钮映射：raw00→mosaic、raw01→starry、raw10→candy、raw11→feathers。

## 产物

- `deliverable/four_style_tiers_20261031/`
  - bit `06d3ad8a…`
  - bin `d90d0fbd…`（313,048 B，20 档）
  - elf `f2f8ad0b…`
  - web/、20 个 header、changes、`captures/candy_default.png`
- 实板：上电 G2 → candy，`style_tier_index={2,2,2,2}`；引擎首字
  `0x513fe419` 与 candy_sw2p5（带 DC）一致；FPS31。

## 扩展

新增风格/档只需加 board header、include、table 一行；70 档约 1.1 MB，
仍小于 4M；存储只在 DDR，不占 XLR。超过 4M 改 `LENGTH` 一行。
