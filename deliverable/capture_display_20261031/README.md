# 全幅采集 + 新显示 + 启动动画 + FPS + mosaic（2026-10-31 最终版）

## 状态

- **基线**：`deliverable/qse_mainline_merge_20261030/`（原版 qse_master，已实测可跑）。
- 在其上合入：
  - 采集全幅 3×3 面积平均（1920×1080→640×360，上下各 60 行黑边）；
  - AE 全幅测光（`ae_in_crop=1'b1`，样本数 2,073,600）；
  - 显示：对比模式左完整原画/右完整风格（等比、上下各 180 行黑边）；
    KEY1 单画面风格 320×180 4× 铺满 1280×720；
  - **上电启动动画**：复用 boot_splash 模块/图片，RTL 上电约 56 ms 后自动播放
    （渐入/停留/渐出约 2.6 s），约 7.2 s 后自动切到实时画面；
  - **FPS 文字叠加恢复**：5×7 字模放进 **1 块 BRAM（128×5）**，不再吃 LUT；
  - **风格 bank3 替换**：原 `red_v3_dc`（呐喊）→ **`mosaic_t025`**
    （`mosaic_glass_t025_20261031_1650`，XOR `0x9da15c61`）。
- 旋钮 G2（raw 10）/ BLE `SLOT,3` / `STYLE 3` 选择 mosaic_t025；
  其余档位/按键/BLE/4 风格切换机制不变。

## 产物

| 文件 | md5 | 说明 |
|---|---|---|
| `ti60f225_oob.bit` | `06d3ad8aed317e6162c1b87febc1d375` | XLR **60,385/60,800（99.32%）**，RAM **254/256**，vid +0.411 ns，core +2.438 ns |
| `soc_video_app.bin` | `5ea88e8c0b3dc6818c4490ab7887b742` | 含 mosaic bank3（94,852 B） |
| `soc_video_app.elf` | `cc5f45a3a93e5f47a618233b103b8e61` | 配套 ELF |

**位流和固件必须成对使用**。

## 实板验证（2026-10-31）

- `captures/boot_animation.png`：上电启动图（XJI 小疆 Viewfinder）实抓；
- `captures/compare.png`：动画后自动切实时对比；右侧为 **mosaic_t025**，左上角 **FPS31**；
- `captures/single.png`：单画面 mosaic 4× 全屏、无黑边、FPS31；
- 读固件状态：`style_active_bank_index=3`、`app_style_switches=1`、无错误位；
- CPU PC 正常（如 `0x3efc`）。

## 上板

```bash
# 位流（JTAG）
G:/Efinity/2026.1/bin/efx_run.bat ti60f225_cam_hdmi.xml -f program --pgm_opts mode=jtag

# 固件（OpenOCD；路径不要带空格）
openocd.exe -f software/firmware/openocd/soc_video.cfg \
  -c "reset halt" \
  -c "load_image soc_video_app.bin 0x1000 bin" \
  -c "reg pc 0x1000" -c "resume" -c "shutdown"
```

默认 `0xF8100130=3`（对比）；写 `1` 切单画面。

## 源码

完整可构建工程：`F:/fm_qse_int_1031/`。
本目录 `changes/` 放关键差异：采集/显示/启动动画/FPS BRAM 字模/bank3 mosaic、
`ti60f225_cam_hdmi.xml`、`ti60f225_oob.peri.xml`、`assets/fps_font.hex`、
`software/firmware/style_bank_mosaic_t025.h` 等。

构建：

```bash
G:/Efinity/2026.1/bin/efx_run.bat ti60f225_cam_hdmi.xml -f compile
bash tools/build_firmware.sh
```

## 已知项

- mosaic 是 **t025 档**（纹理 +18%、结构 −0.086）；同家族 t05/l200 需另给 artifact；
- 对比模式上下黑边是两幅完整 16:9 并排的几何必然；
- JTAG 配置易失，板子重新上电会回 flash 旧位流；要用本版需重烧；
- FPS 字模在 BRAM 后，RAM 只剩 2 块，后续加功能要先看资源。
