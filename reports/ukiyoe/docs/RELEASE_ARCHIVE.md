# 稳定版本备份与标注规范

> 目的（用户要求）：**每次有稳定版本并验证后，备份 bit 并标注，减少额外综合工作量。**
> 日期：2026-10-17

---

## 一、为什么要归档

综合一次（Efinity compile）约 15–25 分钟，且占用机器。

但**已验证过的 bit + 固件可以重复烧录** —— 只要归档时记录哈希，
以后想回到任何历史版本，直接从归档烧回去，**不必重新综合**。

所以规则是：

| 时机 | 动作 |
|---|---|
| 只在**综合出 bit** 时 | ❌ 不归档（未验证，可能是坏的） |
| **上板验证通过**后 | ✅ **归档 + 标注**，从此可重复烧录 |

---

## 二、目录结构

```
reports/ukiyoe/releases/
  <tag>/
      <tag>.bit            上板实际烧的那个 bitstream
      <tag>.hex            SPI 镜像（ftdi_program.py 需要的就是它）
      <tag>_fw.bin         通过 OpenOCD 加载的固件
      MANIFEST.json        哈希 / 来源 / 验证证据 / 烧录方法
```

**tag 命名**：`<日期>_<短描述>`，例如 `20261017_single_panel`。

---

## 三、归档（验证通过后执行）

```powershell
python tools/archive_release.py `
  --tag 20261017_single_panel `
  --bit outflow_nosplit/ti60f225_oob.bit `
  --hex outflow_nosplit/ti60f225_oob.hex `
  --fw  reports/ukiyoe/firmware/soc_video_app_v15.bin `
  --uart-note "DISP 60 ERR 0 CSI 0 AXI 0; NN 10; single-panel" `
  --note "关闭左右双画面：每行只读一次结果区，显示读流量减半"
```

**要点**：

- `--uart-note` 是**验证证据**。填了才算「已验证发布」；不填则 MANIFEST 会明确警告
  「only synthesised, not verified」，防止以后误当成验证过的版本。
- 脚本会记录 **git revision** 与**工作区是否 dirty**，便于追溯。

---

## 四、从归档烧录（不重新综合）

```powershell
# 先干跑核对哈希（不碰板子）
python tools/flash_release.py --tag 20261017_single_panel --dry-run

# 真正烧录：bitstream 走 JTAG，固件走 OpenOCD load_image
python tools/flash_release.py --tag 20261017_single_panel

# 只烧 bitstream
python tools/flash_release.py --tag 20261017_single_panel --skip-firmware
```

脚本行为：

1. **逐个校验归档产物的 SHA256** 与 MANIFEST 是否一致（不一致就拒绝烧）
2. **自动探测 FTDI URL**（线缆重插后 bus:address 会变，不能写死）
3. 烧 bitstream → 等 6 秒让 DDR 校准 → OpenOCD 加载固件
4. **检查 `bytes written` 才 resume**（skill 的铁律：加载失败时 resume 会让 CPU 跑飞）

---

## 五、现有版本状态

| tag | 内容 | 状态 |
|---|---|---|
| `20261017_v15_dual` | v15 系数 + **左右双画面** | ⏳ 待归档（已上板验证：DISP 60 / ERR 0 / CSI 0 / AXI 0） |
| `20261017_single_panel` | v15 系数 + **单画面**（本轮的 fps 优化） | ⏳ 综合中，待上板验证 |

---

## 六、与 skill 的关系

本规范是 `ti60f225-flash-debug` skill 的**补充**：skill 讲「怎么烧」，
本规范讲「烧过且验证过的版本怎么留下来」。

skill 里的 FTDI URL 是历史值（`…:1:4/2`）。**实测当前是 `…:3:3/2`**，
所以 `flash_release.py` 每次先探测再烧，不依赖 skill 里写死的值。
