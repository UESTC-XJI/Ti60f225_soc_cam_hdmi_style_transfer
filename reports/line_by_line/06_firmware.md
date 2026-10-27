# 固件逐行阅读

> 范围：`software/firmware/` 全部自研源文件（9 个编译单元 + 7 个头文件），`software/bsp/` 仅做被引用 API 的语义核对。
> RTL 交叉核对：`rtl/soc_integration/video_apb_ctrl.sv`、`rtl/style/style_accel.sv`、`rtl/style/style_video_system.sv`、`rtl/accel_rowpipe/style_network_rowpipe.sv`、`rtl/accel_rowpipe/rowpipe_engine.v`（**只读，未改任何文件**）。
> 产物核对：`software/firmware/build/soc_video_app.map`、`artifacts/*.bin`（只读）。**未编译固件**。
> 全文数字凡标"实测/核对"的，均由脚本对上述文件计算得出；标"推测"的单独标注。

---

## 结论摘要（5 条）

1. **22,512 B / 1,407 beat 是过时数字，14,448 B / 903 beat 才是完整 blob，不是截断。**
   RTL 的层偏移表 + 12 层描述符算出的总需求恰好 = 903 beat：
   L0(ci=3)=40、L1(ci=4)=49、L2–L10(ci=8)=9×85=765、L11(ci=4)=49 → 40+49+765+49=**903**，
   与 `rowpipe_engine.v` 的 `wbase_of`（0,40,89,…,854）和 `854+49=903` 完全吻合。
   22,512 B 来自另一个文件 `model/weights_blob_D_sw1e5_640.bin`（磁盘上就是 22,512 B，1,407 beat，
   其中 L11 段有 553 beat）；该 blob 与当前任何权重头文件都不逐字相同（首 14,448 B XOR = `0x46ad5eed`，
   末 14,448 B XOR = `0x6ae133f8`）。所以 0x06F00000 后面那 8 KB **不需要写**，也没有"ci 上限 16 造成的空洞"。

2. **`style_driver.c` 的自检只校验 XOR，完全不校验像素；而且失败分支是死码。**
   `style_selftest.h` 的 `style_test_input[768]` / `style_test_expected[768]`（共 6,144 B）**没有任何代码引用**，
   链接时被 `--gc-sections` 丢弃（map 文件里查不到符号）。因此 `main.c:58` 打印的
   "STYLE INT8 RGB self-test PASS" 没有任何证据支撑；`style_init_and_selftest()` 的 `-6` 返回码也永远不可达
   （`app_style_selftest_errors` 全工程无自增点）。

3. **AE 的 4,989 上限是固件自己设的，不是硬件限制。**
   `camera_3a.c:31` 把 VTS 改写成 2500，`camera_3a.c:58` 用 `maximum = 2*vts-11 = 4989` 推出上限。
   把 `CAMERA_VTS_OVERRIDE` 提到 5000，上限就变成 9,989（代价是帧率按 VTS 比例下降，注释说 2500 行 ≈ 18 fps）。
   与 `ARCHITECTURE_FULL.md` §八 #7 记为"传感器进光量/硬件限制"不一致 —— **可以靠改常量突破**。

4. **AWB 失效是 RTL 硬连线 0，固件侧已无路可走；而且 AWB 一旦"复活"，3A 会立刻自杀。**
   `video_apb_ctrl.sv:119-127` 把 0x180/0x184/0x188/0x18c/0x1a0 全部 `prdata=32'd0`，
   `camera_awb.c:13-14` 的守卫因此必然 return 0，`camera_3a.c:168` 的 `!camera_awb_target(...)` 恒真 → 永不写增益。
   **但** `camera_3a.c:109` 要求 `VIDEO_G_ACTIVE == 256`，而 `camera_3a.c:172` 现在写的是 `STYLE_G_GAIN=290`：
   只要有人把 `app_awb_mode` 切到 `AWB_FIXED` 或 AWB 统计硬件被补上，第一次增益握手就会 `status=6, enabled=0`，
   3A 永久停摆。这是本次阅读发现的**最值得修的一处**（当前不可达，属定时炸弹）。

5. **固件仍在驱动一个已经被 RTL 删掉的 OSD 文本页，导致每次开机 +250 ms 停顿、之后每秒一条超时错误。**
   `video_apb_ctrl.sv:24-30`：`paddr<=0x30` 全部走 legacy 解码（除 0x00 外读回 0，写被吞掉，不报错），
   且 `o_video_ready` 被硬连成 1。于是 `osd_write_string("MONET VGA")`、`osd_submit_string()`、
   `osd_set_video_ready()` 全部是"向空地址写字"，`osd_wait_ack()` 只能等满 250 ms 后返回 -1。
   同一根因还让 `style_submit_metrics()` 的 `DISP` 字段（读 0xf8100024）恒为 0。

---

## 启动到出图的完整时序（带超时与失败码）

### 阶段表

| # | 代码位置 | 动作 | 等待/超时 | 失败分支与返回码 |
|---|---|---|---|---|
| 0 | `start.S:7-18` | 关 MIE、`mie=0`、设 gp/sp、`mtvec=trap_entry`、`.word 0x0000500f`(D-cache 无效化)+`fence.i` | 无 | 无 |
| 1 | `start.S:19-29` | 拷 `.data`（LMA→VMA，逐字节 `lbu/sb`） | 无 | 无 |
| 2 | `start.S:30-38` | 清 `.bss` | 无 | 无 |
| 3 | `start.S:39` | `call main` | 无 | 返回则 `firmware_exit` 死循环 |
| 4 | `main.c:44` | `osd_set_video_ready(0)` | 无 | 写 0x28 属 legacy，**无效果** |
| 5 | `main.c:45` | `bsp_init()` → UART 115200（`bsp.h:129-136`） | 无 | 无 |
| 6 | `main.c:47` | `app_ddr_test()`：0x01000000 起 64 KiB，2 pass，图案 `seed^(i*4)` | 无超时 | 失败 → 打印 `DDR scratch FAIL` 后 **`for(;;)` 死机**（`main.c:49`） |
| 7 | `main.c:52` | `style_init_and_selftest()` | 见下 | `-1` MAGIC 错 / `-2` 空闲等待超时 1 s / `-3` XOR 不匹配 / `-6`（不可达）→ **死机**（`main.c:56`） |
| 8 | `main.c:59` | `style_stream_enable()` → `regs[1]=16` | 无 | 无 |
| 9 | `main.c:60` | `camera_bus_init()` 配 I2C（div=3, timeout=HZ/10, tsuDat/tLow/tHigh≈1/3·1/2 位时间） | 无 | 无 |
| 10 | `main.c:61` | `bsp_uDelay(20000)` = 20 ms | 20 ms | 无 |
| 11 | `main.c:62` | `camera_init_cpu()`：`i2c_recover` → `verify_id` → 165 条表 | 每步 5 ms（`BSP_CLINT_HZ/200`） | `-4` recover 失败 / `-3` ID≠0xcd6b / `-1` 写失败 / `-2` 回读不符 → 打印后**继续跑**，每秒重试 |
| 12 | `main.c:69` | `osd_write_string("MONET VGA")` | 250 ms（`HZ/4`） | 恒失败 → `-1`，+1 `app_osd_errors`，打印 `OSD initial COMMIT timeout` |
| 13 | `main.c:76` | `osd_set_video_ready(1)`（需 camera_rc==0 且 osd_rc==0） | — | 条件几乎恒不成立；且该写本身无效 |
| 14 | `main.c:79` | `camera_3a_init(&app_3a, now)` | I2C 5 ms/步 | `-1` `video_probe` 失败 / `-2` 读 VTS/曝光/0x3802 失败 / `-3` vts<8；写 VTS 失败只 `last_error=5` 不返回错 |
| 15 | `main.c:85-122` | 主循环 | 1 ms 服务 / 1 s 上报 | 见下 |
| 16 | 出图 | 首帧捕获 → `nn_start`（`style_accel.sv:75-77` 需 `auto_start && auto_ready && stream_enable`）→ 12 层 → 写 result → 显示端读 | 帧级，~55 ms/次 | CNN 错误位进 `app_style_errors`，UART `ERR` 计数可见 |

### 主循环（`main.c:85-122`）

| 触发 | 动作 | 超时 | 失败表现 |
|---|---|---|---|
| 每 1 ms（`now-last_service>=HZ/1000`） | `camera_3a_service()`；`video_hist_poll()`（`app_hist_enable` 恒 0 → **死路**） | — | — |
| 每轮 | `if(osd_pending) osd_poll()` | 250 ms → `OSD metrics COMMIT timeout`，+1 `app_osd_errors` | **每秒必然发生一次**（见上） |
| 每 1 s | 相机失败则 `camera_recover()`（recover+stop+5 ms+全表重init） | 每步 5 ms | 仍失败则 +1 `app_camera_errors`，无上限重试 |
| 每 1 s | `style_submit_metrics()` → `osd_submit_string()` | — | 返回非 0 时读 0xf8100020（legacy→0）判错 |
| 每 1 s | `camera_3a_log()`、`style_update_metrics()`、`style_log_ddr()`（2 行）、`++app_metrics_updates` | — | UART 输出约 4 行/秒 |

### `style_init_and_selftest()` 内部时序（`style_driver.c:33-56`）

| 行 | 动作 | 判据/超时 | 失败码 |
|---|---|---|---|
| 34 | 读 `regs[0]` 比 MAGIC `0x3154534e` | 立即 | `-1` |
| 35 | `regs[1]=0`（清 stream_enable 与 start 位） | — | — |
| 36-37 | 等 `(regs[2]&17)==16`，即 bit0 `pending==0` **且** bit4 `coeff_idle==1` | 1 s（`BSP_CLINT_HZ`） | `-2` |
| 40-41 | 把 3,612 word 写到 `0x06F00000`（14,448 B） | 无 | 无 |
| 42 | `fence rw,rw` + `.word 0x0000500f` | — | — |
| 43-45 | 从 DDR 回读 3,612 word 求 XOR，比 `ROWPIPE_WEIGHT_XOR` | — | `-3` |
| 46-48 | PLIC：id 16 优先级 1、阈值 0、使能 1 | — | 无返回值检查 |
| 49 | `regs[2]=6`（清 done+error sticky）、`regs[3]=1`（irq_enable） | — | — |
| 50-51 | `csrs mie,(1<<11)` + `csrsi mstatus,8`（开 MEIE+MSTATUS.MIE） | — | — |
| 52 | `regs[4]=0x05000000`、`regs[5]=0x05800000`、`regs[6]=0x01e00280` | — | 无 pslverr 检查 |
| 55 | `return app_style_selftest_errors ? -6 : 0` | — | **恒 0** |

**要点**：PLIC 在 `regs[4..6]` 之前使能，但 `stream_enable=0`，`auto_start` 被 `style_accel.sv:75` 的
`&& stream_enable` 挡住，所以不存在"配置未写完就被自动启动"的竞态（顺序是对的）。
`regs[6]=0x01e00280` → geometry[9:0]=640、[25:16]=480，过 `config_ok`（`style_accel.sv:38-42`）：
640∈[32,640] 且 640&31=0、480∈[24,480]、source∈[0x05000000,0x05800000-0x12C000]、result∈[0x05800000,0x06000000-0x12C000] 全部满足。

---

## 自查表：APB 偏移 × RTL 实体 × 固件访问点

### STYLE 区 `0xf8100200`（`paddr` 8 位；`style_accel` + `style_video_system` 的 prdata 二选一）

| 偏移 | RTL 实体（文件:行） | 读/写语义 | 固件访问点 |
|---|---|---|---|
| `0x00` | `style_accel.sv:83` | MAGIC `0x3154534e` | `style_driver.c:34` |
| `0x04` | `style_accel.sv:67-70,84` | bit4 `stream_enable`；bit0 写 1 触发 start（清 done_sticky、锁存 mailbox） | `style_driver.c:35`(0)、`:57`(16) |
| `0x08` | `style_accel.sv:71,85` | 读 `{…,coeff_idle[4],0[3],error[2],done[1],pending[0]}`；写 bit1 清 done、bit2 清 error | 读 `:15,37`；写 `:21`(`status&6`)、`:49`(6) |
| `0x0c` | `style_accel.sv:72,86` | `irq_enable[0]` | `style_driver.c:49` |
| `0x10/14/18` | `style_accel.sv:73,86` | `source_cfg`/`result_cfg`/`geometry`（写时 `config_ok` 校验，写错置 pslverr） | `style_driver.c:52` |
| `0x1c` | `style_accel.sv:87` | `last_cycles` | `style_driver.c:17` |
| `0x28` | `style_accel.sv:73,87` | `coefficient_index`（rowpipe 忽略 coef 口：`style_network_rowpipe.sv:27,143`） | 未使用 |
| `0x30` | `style_accel.sv:87` | `{acknowledged, issued}` | 未使用 |
| `0x34` | `style_accel.sv:88` | 常数 `148500000` | 未使用（固件自己写死 `/148500`） |
| `0x38/3c/40` | `style_video_system.sv:78` | `captured`/`dropped`/`inferred`（来自 `style_frame_store`） | `style_driver.c:59-60,110-111,120` |
| `0x44/48/4c` | `style_video_system.sv:78` | `infer_errors`/`display_frame_id`/`display_dma_errors` | `:102`(IERR)、`:122`(regs[19])、`:101`(DME) |
| `0x50` | `style_video_system.sv:78` | `bridge_errors` | `:122`(regs[20]) |
| `0x54` | **不存在**（`style_ddr_profiler.sv` 从未被实例化；`style_accel` 无此偏移） | 写被静默忽略，读回 0 | `style_log_ddr:71,73`（写 1/0 想锁存） |
| `0x58…0x84` | **不存在** | 读回 0 | `style_log_ddr:72` 读 12 个计数器 |
| `0xa8/ac` | `style_accel.sv:89` | `read_cycles`/`compute_cycles` 快照（rowpipe 恒 0，见下） | `:18` |
| `0xb0/b4/b8` | `style_accel.sv:90` | `prefetch_starts`/`completions`/`overlap` 快照（rowpipe 恒 0） | `:19` |
| `0xbc` | **不存在**（`ARCHITECTURE_FULL.md` §五 声称有"显示模式"，RTL 无此偏移） | — | 未使用 |

> **两个恒 0 的坑（RTL 侧确认）**：`style_network_rowpipe.sv:137-141` 把
> `stat_read_cycles/compute_cycles/prefetch_starts/prefetch_completions/overlap_cycles` 全赋 0，
> 所以 `style_log_ddr` 的 `RPMS/CPMS/PF/PFC/OVLP` 永远打印 0；0x54/0x58… 无实体，
> 所以第一行的 `T/AR/DOWN/RGAP/RBP/DBP/AW/W/B/IDLE/RB/DRB` 也全是 0。**这半行遥测是"假数据"，不代表真实 0。**

### VIDEO 区 `0xf8100000`（`paddr` 16 位；`video_apb_ctrl.sv`）

| 偏移 | RTL 实体（行） | 语义 | 固件访问点 |
|---|---|---|---|
| `0x000` | `:25` legacy | `CORE_ID 0x4f534431` | `video_ctrl.c:5` |
| `0x004…0x030` | `:24-30` legacy | 读回 0（0x00 除外）、写吞、**不报 pslverr**；`o_enable/o_char_*/o_commit_*` 全为常数 0，`o_video_ready` 硬连 1 | `soc_video_driver.c:34-40`（OSD 全部）、`main.c:44,115`、`style_driver.c:114` |
| `0x034` | `:70` | `0x00010000` | `video_ctrl.c:5` |
| `0x038` | `:71` | `0x000001ff` | `video_ctrl.c:6`（REQUIRED=0x128 ⊂ 0x1ff ✓）、`video_stats.c:16`（bit6 ✓） |
| `0x03c` | `:72` | `reset_status[4:0]` | 未使用 |
| `0x040/044/048` | `:73-75,203-205` | `cap_shadow` R/G/B（16 位各） | `video_ctrl.c:10` |
| `0x04c` | `:76,206` | `disp_shadow[31:0]` tone（掩码 `0x00ffff01`） | 未使用 |
| `0x050` | `:77-81,207-210` | bit0→capture commit、bit1→display commit；写错置 pslverr + `fault_sticky[5]`（`:200`） | `video_ctrl.c:11` |
| `0x054` | `:82` | `{disp_busy, cap_busy}` | `video_ctrl.c:9`、`camera_3a.c:104,170` |
| `0x058/05c` | `:83-84` | `cap_seq` / `disp_seq` | `camera_3a.c:108,123,171` |
| `0x060/064/068` | `:85-87` | `cap_mirror` R/G/B（ack 时锁存的生效值） | `camera_3a.c:108-109,163,193` |
| `0x080/084` | `:89-90,211-212` | `disp_shadow` lift/hist（0x080 写 bit1 会置 value_error） | **未使用**（固件从不写 lift） |
| `0x0c0…0x0e8` | `:95-106` | AE 统计：seq/y_sum/(time恒0)/flags/AE_METER/frame/cfg/sensor_frame/samples/hot | `video_stats.c:4-9` |
| `0x0ec` | `:107` | `SOURCE = 1` | `video_stats.c:8,11`、`video_ctrl.c:6` |
| `0x100/104` | `:108-109,214` | `disp_shadow[82:80]` / mirror | 未使用 |
| `0x108…0x12c` | **不在 case 内** → `default: ext_legal=0` → **每次访问都置 pslverr**，读回 0 | 直方图命令/状态/数据/元数据 | `video_stats.c:17-38`（`video_hist_poll`，因 `app_hist_enable` 恒 0 而不执行） |
| `0x140` | `:110,197` | `fault_sticky` | `style_driver.c:99` |
| `0x144` | `:111` | `drop_count32` | 未使用（改用 style 区 0x3c） |
| `0x148` | `:112` | `axi_errors32` | `style_driver.c:103` |
| `0x14c` | `:113` | `underflows32` | `style_driver.c:95` |
| `0x150/154/158` | `:114-116` | raw/resize/display 帧数 | 未使用 |
| `0x15c` | `:117` | `csi_errors[6:0]` | `style_driver.c:100` |
| `0x180…0x1a0` | `:119-127` | **硬连线 `prdata=32'd0`（AWB 统计整块缺失）** | `video_stats.c:6-7` → `camera_awb.c:13-14` |
| `0x190/194` | `:123-124,215-216` | `cap_shadow[87:56]`（滤镜 lo/hi/offset）、`[103:88]`（neutral 512） | **未使用**（固件从不写，保持 RTL 默认 8/248/512） |

> **`0x0d0 VIDEO_FLAGS` 位域**（`video_apb_ctrl.sv:100`）= `{28'd0, faults_sync[2], faults_sync[1], faults_sync[0], 1'b1}`：
> bit0 **恒 1（统计有效）**、bit1 = capture_fault、bit2 = resize_fault、bit3/4 = 0。
> 固件 `camera_3a.c:89,122` 用 `&0x26`（bit1/2/5）判故障、用 `&1` 判有效 —— **与 RTL 一致**（bit5 恒 0，无害）。
> 增益写入路径：`camera_3a.c:63` → `video_ctrl.c:8-11` → 0x040/044/048 + 0x050=1 → `cap_shadow` →（`vs` 边界 cdC）
> `cap_pending` → `cap_mirror` + `cap_seq++`。`filter_valid`（`:63`）= `[71:64]=8 > 0`、`8 < [79:72]=248`、`[103:88]=512 ≥ 256`，默认值恒过。

---

## 权重版本对照表

### 头文件 ↔ XOR（全部实测自洽）

| 变体 | 头文件 | 声明 XOR | 实算 XOR | word 数 | 字节 |
|---|---|---|---|---|---|
| **redsky_v4（工作区当前）** | `software/firmware/rowpipe_weights.h` = `variants/rowpipe_weights_redsky_v4.h` | `0xcb1d96c9` | ✅ 一致 | 3,612 | 14,448 |
| redsky_q（git HEAD） | `variants/rowpipe_weights_redsky_q.h` | `0xc06d273c` | ✅ 一致 | 3,612 | 14,448 |
| starry g065 | `variants/rowpipe_weights_g065.h` | `0xff827fe7` | ✅ 一致 | 3,612 | 14,448 |
| starry g075 | `_backup_179fps/rowpipe_weights_starry_g075.h` | `0xf6a82050` | ✅ 一致 | 3,612 | 14,448 |
| starry g085 | `variants/rowpipe_weights_g085.h` | `0xcdc157c0` | ✅ 一致 | 3,612 | 14,448 |
| ink v14a | `variants/rowpipe_weights_ink_v14a.h` | `0x434fd8b6` | ✅ 一致 | 3,612 | 14,448 |
| ink v14a_safe | `variants/rowpipe_weights_ink_v14a_safe.h` | `0x20eb625b` | ✅ 一致 | 3,612 | 14,448 |
| v13（备份） | `rowpipe_weights.h.v13_backup` | `0x6efbe663` | ✅ 一致 | 3,612 | 14,448 |
| D_cap8_ft（仓库原版） | `rowpipe_weights.h.orig` = `model/rowpipe_weights.h` | `0xc7eaf900` | ✅ 一致 | 3,612 | 14,448 |

> **文件名陷阱（实测）**：`_backup_179fps/` 里有两个都带 g075 的头文件 ——
> `rowpipe_weights_starry_g075.h` 才是真的 starry g075（`0xf6a82050`）；
> 而 `rowpipe_weights_g075_starry.h` 的 XOR 是 **`0xc7eaf900`**（等于 `.orig`/`_current.h` 的原版权重），
> 名字与内容不符。要复现"唯一验证可用"的配置，**必须用前者**。

### artifacts/*.bin 内嵌权重（实测定位 + 逐字比对）

| bin | 大小 | 权重偏移 | 内嵌 XOR | 对应头文件 | 文档记录状态 |
|---|---|---|---|---|---|
| `soc_video_app_redsky_v4.bin` | 27,092 | `0x3064` | `0xcb1d96c9` | ✅ redsky_v4 | **板上就是 v4**（`BOARD_REPLY_v4_is_v4.md:11-20` 逐字节一致）；`OUTPUT_RANGE_BOARD_VERIFY.md` 有 DDR σ 33–37 实测 |
| `soc_video_app_redsky_q.bin` | 28,268 | `0x34F8` | `0xc06d273c` | ✅ redsky_q | 分支 `feature/colour-calib-redsky-q` 的 HEAD 权重；无独立验证报告 |
| `soc_video_app_cap8_ae_crop_goal128_vts2500_max4989.bin` | 28,260 | `0x34F0` | `0xc7eaf900` | ✅ .orig/model | 仓库原版 |
| `soc_video_app_v13.bin` | 28,268 | `0x34F8` | `0x6efbe663` | ✅ v13_backup | ❌ 右侧纯灰、无输出（`WEIGHT_VERSION_TEST_REPORT.md:17`） |
| `soc_video_app_v14a.bin` | 28,268 | `0x34F8` | `0x434fd8b6` | ✅ ink_v14a | ❌ 纯灰（同上 :16） |
| `soc_video_app_v14a_safe.bin` | 28,268 | `0x34F8` | `0x20eb625b` | ✅ ink_v14a_safe | ❌ 纯灰（同上 :18） |
| `soc_video_app_v14a_VERIFIED.bin` | 28,268 | `0x34F8` | `0x423d41f9` | ⚠️ **仓库里没有这个头文件** | 文件名带 VERIFIED，但权重不可由源码复现 |
| `soc_video_app_redsky.bin` | 28,268 | `0x34F8` | `0xb2ae9611` | ⚠️ 无对应头 | — |
| `soc_video_app_greatwave.bin` | 28,268 | `0x34F8` | `0x433c18e4` | ⚠️ 无 | — |
| `soc_video_app_qianli.bin` | 28,268 | `0x34F8` | `0x0935262c` | ⚠️ 无 | — |
| `soc_video_app_qianli_v5.bin` | 28,268 | `0x34F8` | `0xc87b8a7d` | ⚠️ 无 | — |
| `soc_video_app_scream.bin` | 28,268 | `0x34F8` | `0x6127e407` | ⚠️ 无 | — |
| `soc_video_app_scream_pastel.bin` | 28,268 | `0x34F8` | `0x54ede8f4` | ⚠️ 无 | — |
| `soc_video_app_ink_v4.bin` | 27,092 | `0x3064` | `0x47cf8d63` | ⚠️ 无 | — |
| `soc_video_app_scream_v4.bin` | 27,092 | `0x3064` | `0x478cd058` | ⚠️ 无 | — |
| `soc_video_app_wave_v4.bin` | 27,092 | `0x3064` | `0x42c81f1f` | ⚠️ 无 | — |

> 组合规律：**27,092 B 的 bin 权重在 `0x3064`，28,26x/28,272 B 的在 `0x34F8`（或 `0x34F0`）**（两个偏移均实测逐字命中）。
> 差值约 1,176 B，与 `BOARD_REPLY_v4_is_v4.md:16-22` 记的 "+1,180 B = camera_3a.c 的增益校准" 同量级。
> **推测（未验证）**：`*_v4.bin` 系列是不带色彩校准的模型侧构建，28,268 B 系列带校准 —— 这只解释"大小分两档"，
> 不改变"权重内容按 XOR 逐字对上"这一**已核实**事实。

### 「22,512 B / 1,407 beat」的裁决（事实，非推测）

| 证据 | 数值 | 来源 |
|---|---|---|
| `model/weights_blob_D_sw1e5_640.bin` 磁盘大小 | 22,512 B = 1,407 beat（恰整除） | 实测 |
| 该 blob 的分段实测（按引擎 `wbase_of`） | L0 40、L1 49、L2–L10 各 85、**L11 553**（非零 529） | 实测 |
| RTL 需要多少 beat（按 `DESCS` 逐层算 `ci*9+13`） | 40+49+9×85+49 = **903** | `style_network_rowpipe.sv:79-92` + `rowpipe_engine.v:242-259` |
| 头文件承载 | 3,612 word = 903 beat = 14,448 B | 实测 |
| blob 首 14,448 B 的 XOR | `0x46ad5eed`（≠ 任何头文件） | 实测 |
| blob 末 14,448 B 的 XOR | `0x6ae133f8`（≠ 任何头文件） | 实测 |

**结论**：
- 当前 12 层 RTL 的权重契约就是 **903 beat / 14,448 B**，固件写得完整、不多不少，**0x06F00000 之后不欠数据**。
- 22,512 B 是另一份导出（`sw1e5_640`，L11 = 553 beat，结构与本 RTL 的 L11=49 beat 不同）的历史产物，
  文件还在 `model/` 里，但**不对应当前 bit**；`style_driver.c:38-39` 的注释、`ARCHITECTURE_FULL.md:175/261/339`、
  `MODEL_OUTPUT_RANGE_FIX.md:67` 抄的是这个旧数字。
- 「ci 上限 16 导致 8 通道空洞」的猜测**不成立**：数组里的零是 beat **内部**的打包留白
  （例如 L0 的 beat 形如 `x,0,0,0`，16 B 里只有部分字承载权重/BN），与 beat 计数无关。

---

## 逐文件章节

### 1. `software/firmware/start.S`（101 行）

**职责**：`_start` 复位入口 + trap 分发。在整个流程里是第 0 步，先于 C 运行时。

**关键函数**
| 符号 | 签名 | 调用者 | 副作用 | 失败 |
|---|---|---|---|---|
| `_start` | `void _start(void)` | 复位向量（`ENTRY(_start)`，PC=0x1000） | 关中断、设 gp/sp、装 mtvec、D-cache 无效化、拷 .data、清 .bss、`call main` | 无返回；main 返回后 `firmware_exit` 死循环 |
| `trap_entry` | 异常入口 | `mtvec`(直接模式) | 保存非 callee-saved 16 个寄存器；`mcause==0x8000000b` 走 `firmware_interrupt_handler` 后 `mret`；否则写 `firmware_trap_*` 后 `trap_halt` 死循环 | 非外部中断（含 CLINT 定时器中断）→ **CPU 静默停机** |

**逐行要点**
- `7-8`：`csrci mstatus,8` 清 MIE，`csrw mie,zero` —— 先把中断全关，符合"运行时单 hart"。
- `9-13`：`norelax` 下取 `__global_pointer$`（`app.ld:14`，.sdata 后 +0x800）与 `_sp`（`app.ld:27`）。
- `14-15`：`mtvec=trap_entry`，直接模式（低 2 位=0）。
- `16-18`：`.word 0x0000500f` 是 Sapphire 文档的 D-cache 全无效化，紧接 `fence.i`。
- `19-29`：`.data` 逐字节拷贝（`lbu/sb`，未用字对齐拷贝，慢但简单；.data 只有 4 B，无性能问题）。
- `30-38`：`.bss` 清零（`app_hist` 324 B、`app_3a` 96 B 等）。
- `47-86`：trap 保存/恢复；**注意只存 ra/t0-t6/a0-a7**，未存 gp/tp/s0-s11 —— 对 C ABI 合法（callee 自行保存），
  但 `firmware_interrupt_handler()` 里若用 `gp` 相对寻址的全局变量，`gp` 在整个 trap 期间不变，安全。
- `87-101`：非外部中断只记录 `mcause/mepc/mtval` 三个全局后挂死，**没有任何 UART 输出** → 现场只能靠调试器看变量。

**风险与疑点**
| 位置 | 疑点 | 置信度 |
|---|---|---|
| `start.S:65-68` | 只认 `0x8000000b`（MEI）。CLINT 定时器中断（`0x80000007`）或任何同步异常都会让 CPU 停在 `trap_halt`，板上表现为"跑一会儿就不动了"。当前未开 MTIE，属潜在雷 | 高（代码事实）/ 影响低 |
| `start.S:7,18` | D-cache 无效化后又从 DDR 拷 `.data`：若 `_data_lma` 的数据还在 cache 脏行里（load_image 之后不会），可能拷到旧值。实际由 OpenOCD 写内存，无脏行 | 低 |

**文档偏差**：`ARCHITECTURE_FULL.md` §七 固件表**完全没有** `start.S`/`app.ld` 两行，而它们决定了内存布局与崩溃形态。

### 2. `software/firmware/app.ld`（32 行）

**职责**：链接脚本。定义了固件唯一可用的 DDR 窗口与栈。

**逐行要点**
- `3-4`：`MEMORY { app_ddr : ORIGIN=0x00001000, LENGTH=124K }` —— 0x1000..0x20000。注释写明片上 4 KiB RAM 在 0xf9000000（未用）。
- `5`：`PHDRS` 分 code(FLAGS 5=RX)/data(FLAGS 6=RW)。
- `8-10`：`.init`→`.text`→`.rodata` 全在 code 段（**权重也在 .rodata，跟着代码进 0x1000 起的同一段**）。
- `11-19`：`.data` 里放 `__global_pointer$ = . + 0x800`（标准 RISC-V gp 约定）；`_data_lma = LOADADDR(.data)`。
- `20-25`：`.bss` NOBITS。
- `27-29`：`_sp = 0x20000`；`__stack_bottom = _sp-4096`；`_heap_end = __stack_bottom`（无 malloc，仅占位）。
- `30`：`ASSERT(_end <= __stack_bottom)` —— 编译期兜底。

**实测布局**（`build/soc_video_app.map`，非本次编译）：

| 段 | 起始 | 大小 | 内容要点 |
|---|---|---|---|
| `.init` | 0x00001000 | 0x88 (136 B) | `_start` + `trap_entry` |
| `.text` | 0x00001088 | 0x2D2C (11,564 B) | 全部逻辑 |
| `.rodata` | 0x00003DB4 | 0x40B8 (16,568 B) | `rowpipe_weights` **0x3870=14,448 B**、`camera_init_table` 0x3DE=990 B、字符串 ~2 KB、`__clz_tab` 256 B |
| `.data` | 0x00007E6C | 0x4 | 仅 `app_awb_mode` |
| `.bss` | 0x00007E70 | 0x2BC (700 B) | `app_hist` 324 B、`app_3a` 96 B、各计数 |
| 镜像末尾 | 0x00007E70 | — | `soc_video_app.bin` = 28,272 B（= 0x7E70-0x1000） |

**风险与疑点**
- 124 KiB 窗口只用了 28 KB（22%），**栈底距镜像末尾还有 0x1F000-0x7E70 ≈ 88 KB**，无溢出风险。
- `.rodata` 里 87% 是权重表；**换权重 = 重新链接**（无法运行时下发），这是"变体只能靠烧固件切换"的根本原因。

### 3. `software/firmware/style_driver.c` / `.h`（125 / 13 行）

**职责**：STYLE 区唯一驱动：权重 blob 装载 + XOR 自检 + PLIC/IRQ + 三类遥测（IRQ 快照、DDR 剖面、指标上报）。
在流程里位于"摄像头初始化之前"（`main.c:52`），因为风格网络必须权重就绪才能接收第一帧。

**关键函数**

| 函数 | 签名 | 调用者 | 副作用 | 失败码 |
|---|---|---|---|---|
| `sync_ddr` | `static void sync_ddr(void)` | 仅 `:42` | `fence rw,rw` + D-cache 无效化 | — |
| `style_irq_service` | `void style_irq_service(void)` | `firmware_interrupt_handler:28` | 读 `regs[2]`、`regs[7]`、0xa8/b0/b4/b8；`regs[2]=status&6` 清 done+error；`++app_style_irqs`；error 位则 `++app_style_errors` | — |
| `firmware_interrupt_handler` | `void firmware_interrupt_handler(void)` | `start.S:68` | `plic_claim` 循环；id16→服务；其它 id → `++errors` + `plic_set_enable(...,0)`；`plic_release` | — |
| `style_init_and_selftest` | `int style_init_and_selftest(void)` | `main.c:52` | 见上表；**启动 PLIC 与 MIE** | `-1/-2/-3`（`-6` 不可达） |
| `style_stream_enable` | `void style_stream_enable(void)` | `main.c:59` | `regs[1]=16` | — |
| `style_update_metrics` | `void style_update_metrics(void)` | `main.c:118`、`style_submit_metrics:109` | 读 `regs[14/15/16]` | — |
| `style_log_ddr` | `void style_log_ddr(void)` | `main.c:119` | 两行 UART（每行 320 B 缓冲）；更新 `previous[]` 差分 | — |
| `style_submit_metrics` | `int style_submit_metrics(uint64_t now)` | `main.c:113` | 算 cap/nn fps、拼 80 B 行、UART + `osd_submit_string` | 透传 OSD 的 0/-1 |

**逐行要点**
- `7-12`：基址 0xf8100200；12 个 `app_style_*` 全局（都在 .bss，UART/调试器可读）。
- `13`：`sync_ddr()` —— 见疑点 1。
- `14-24`：IRQ 服务。注释称"completion toggle 保证 APB 快照已稳定"。写 `status&6` 清粘滞位；`fence iorw,iorw`。
- `25-32`：PLIC 分发循环。**默认关闭并释放未知中断源**，避免中断风暴（好设计）。
- `33-56`：自检主体（时序表见上）。
- `57`：`style_stream_enable` 只置 bit4，不置 bit0 —— 启动由视频帧的 `auto_start` 驱动（`style_accel.sv:75`）。
- `62-67`：`put_text`/`put_decimal` —— **不用 printf**（`-nostdlib`），手写十进制。
- `68-106`：`style_log_ddr`。第一行 12 个 DDR 计数器 + 5 个 prefetch 统计；第二行 `VIDEO UF/DUF/DDROP/FAULT/CSI/DME/IERR/AXI`。
  注释解释了"十位字段"和"百分比共用 100 MHz 区间"的用意。
- `107-125`：`style_submit_metrics`。`cap_fps/nn_fps` 用 `ticks` 差分（`BSP_CLINT_HZ/ticks` 定点）；>999 截断；
  `MS = app_style_cycles/148500`（148.5 MHz 周期 → ms）；`ERR = app_style_errors+regs[19]+regs[20]`。

**风险与疑点**

| 位置 | 为什么可疑 | 现象 | 置信度 |
|---|---|---|---|
| `style_driver.c:38-39` | 注释宣称 22,512 B / 1,407 beat，实际只写 14,448 B / 903 beat | 读者会误以为少写 8 KB；实际 903 才是全部（见权重章节） | **确定**（事实级） |
| `style_driver.c:42,13` | 用"D-cache 无效化"（`0x0000500f`）代替写回/刷新 | 若该操作不含写回，脏行被丢弃→DDR 是旧值→`:45` 的 XOR 校验会 `-3` 卡死启动。板上能启动 ⇒ 该 op 实际包含写回或缓存为写透。**但把"正确性"建立在指令语义未文档化上**，属隐患 | 中（现象未复现，逻辑成了） |
| `style_driver.c:55` | `-6` 依赖 `app_style_selftest_errors`，全工程**无自增点** | 返回码永不出现；`main.c:58` 的 "INT8 RGB self-test PASS" 是**无证据的断言** | **确定** |
| `style_driver.c:71-73` | 往 0x54 写 1 想锁存、读 0x58..0x84 想取 12 个计数器 | RTL 无此实体（profiler 未实例化）→ 恒 0 | **确定**（RTL） |
| `style_driver.c:86-87,18-19` | `RPMS/CPMS/PF/PFC/OVLP` 依赖 `stat_*` 快照 | rowpipe 版把它们全部拉 0（`style_network_rowpipe.sv:137-141`）→ 恒 0 | **确定**（RTL） |
| `style_driver.c:114` | `display_fps` 读 `0xf8100024`（VIDEO 0x24） | 属 legacy 窗口（`paddr<=0x30`）→ 读回 0 → **`DISP` 恒 0** | **确定**（RTL） |
| `style_driver.c:21` | `regs[2]=status&6` 是"读后按位清" | 读与写之间新到的 error 会被同一次写清掉（丢一次错误事件） | 中 |
| `style_driver.c:46-48` | PLIC 配置无返回值检查 | 若 PLIC 基址/ID 错，静默无中断；`app_style_irqs` 可发现 | 低 |

**文档偏差**：`ARCHITECTURE_FULL.md:333` 说"只校验权重 XOR，不做像素对比" —— ✅ 正确；
但 §五 STYLE 表把 0x54/0x58… 全漏了（固件在读），又列了 RTL 里不存在的 0xbc。

### 4. `software/firmware/soc_video_driver.c` / `.h`（239 / 17 行）

**职责**：VIDEO APB 的 OSD 部分（**已被 RTL 删除，实为死码**）+ 摄像头 I2C 位操作 + 165 条初始化表执行。
在流程里位于 `main.c:62`（摄像头初始化）和每秒一次的重试/恢复。

**关键函数**

| 函数 | 签名 | 调用者 | 副作用 | 失败码 |
|---|---|---|---|---|
| `i2c_wait_clear` | `static int (uint32_t off, uint32_t mask, uint64_t start)` | 全部 I2C 原语 | 轮询直到 (reg&mask)==0 | `-2` 超时（`BSP_CLINT_HZ/200` = 5 ms） |
| `i2c_start_checked` | `static int (uint64_t start)` | `i2c_address_checked` | `i2c_masterStart` | `-2` 超时 / `-3` START_DROPPED |
| `i2c_byte_checked` | `static int (uint8_t byte, uint64_t start)` | 同上 | 发 1 字节并读 ACK | `-2` 超时 / `-1` **从机 NACK** |
| `i2c_stop_checked` | `static int (int error)` | 收尾 | `masterStop`；异常时 `masterDrop` | 透传 error，否则 `-2` |
| `sapphire_i2c_write16` | `static int (uint16_t reg, uint8_t v)` | `camera_reg_write` | 写 8 位寄存器 | 同上层 |
| `sapphire_i2c_read16` | `static int (uint16_t reg, uint8_t *v)` | `camera_reg_read` | 读 8 位寄存器；**最后一次 NACK 不写进 RX_ACK**（`:101-106` 有意为之） | 同上 |
| `sapphire_i2c_recover` | `static int (void)` | `camera_init_cpu`/`camera_recover` | 排空 RX、drop、recover、清三个 DROPPED 位、检查 SDA/SCL 都为高 | `-2` |
| `camera_init_cpu` | `int (void)` | `main.c:62`、`camera_recover` | recover→verify_id→写 165 条（含延时/回读） | `-4/-3/-1/-2` |
| `camera_recover` | `int (void)` | `main.c:104` | recover→`camera_stop`→5 ms→`camera_init_cpu` | `-4`/`-1`/表内码 |
| `osd_submit_string` | `int (const char*)` | `main.c:69`(经 write_string)、`style_driver.c:124` | 写 80 字符 + COMMIT，置 `pending_osd` | `-1` 仅当指针空或 status bit2 |
| `osd_wait_ack` | `static int (uint32_t old_ack)` | `osd_write_string` | 等 ACK 翻转 | `-1` 250 ms 超时 |
| `osd_poll` | `int (void)` | `main.c:96` | 非阻塞查 ACK | 1 完成 / 0 未完 |
| `publish_metrics` | `static int (int blocking)` | `osd_publish_metrics`/`osd_submit_metrics` | 拼 `RAW/RESIZE/DISP/DROP/ERR` 行 | OSD 返回值 |

**逐行要点**
- `19-31`：OSD 寄存器偏移表（0x00..0x30）。**这些偏移现在全部落在 RTL 的 legacy 窗口里**。
- `34-40`：`osd_write/osd_read` 直接 MMIO；`SOC_DRIVER_HOST` 分支是主机端单测桩（不参与固件构建）。
- `42-86`：I2C 原语。`i2c_byte_checked` 先读一次 `RX_ACK`（**读清 VALID**，`:60`）再 `listenAck`，避免上一笔的 stale ACK 干扰；超时全部有界（好实践）。
- `87-109`：16 位地址读写。写序列：START→0x60→regH→regL→data→STOP；读序列：START→0x60→regH→regL→重复START→0x61→读data。
- `110-136`：`recover`。注释解释"RECOVER 自己会发 STOP，多余的 STOP 会挂住后续恢复"（`:131-133`），并在结束时清三个 DROPPED 位。
- `146-147`：`camera_reg_read/write` 是对外薄封装。
- `148-161`：`osd_wait_ack` 逻辑：`((s&1)!=0) != (old_ack!=0)` —— 需要 ACK 位**翻转**且没有错误位（bit2）。
- `163-186`：提交/轮询。`osd_submit_string` 用乒乓页（`page=((before>>1)&1)^1`），先写 80 个字符再改 CHARADDR 回页首并 COMMIT。
- `188-197`：`camera_read_id` 读 0x3107/0x3108，`camera_verify_id` 要求 == `0xcd6b`。
- `199-209`：`camera_init_cpu` 主循环。`e->readback` 分支**永远不成立**（表里 165 条全是 0，见下）。
- `211-213`：`camera_start/stop` 写 0x0100。
- `223-236`：`publish_metrics`（本固件未调用，`main.c` 走的是 `style_submit_metrics`）。

**风险与疑点**

| 位置 | 为什么可疑 | 现象 | 置信度 |
|---|---|---|---|
| `soc_video_driver.c:148-161` + RTL `:24-30` | 向 legacy 窗口等一个永不出现的 ACK | 开机 `OSD initial COMMIT timeout`（250 ms 停顿）；每秒 `OSD metrics COMMIT timeout` + 计数增长 | **确定** |
| `soc_video_driver.c:206` | `readback` 字段 165 条全 0 → 回读校验死码 | 初始化"写成功"其实未验证；I2C NACK 才会被发现 | **确定** |
| `soc_video_driver.c:175-179` | 字符写循环硬编码 80 字符 / 页容量 | 若文本 >80 字符被截断（当前行 80 B 缓冲刚好） | 低 |
| `camera_init_table.h:151` | `0x0100=0x01`（**开流**）在整表第 151 条，其后还有 0x3200..0x3213 的窗口/裁剪寄存器 | 开流后再改窗口，通常需要重新触发或用 group hold；当前无 0x3812 保护 | 中 |

**文档偏差**：§七 未提 OSD 已被 RTL 删除这一"固件-RTL 不同步"事实。

### 5. `software/firmware/video_ctrl.c` + `video_regs.h`（12 + 63 行）

**职责**：VIDEO 区最小读写原语 + 探测 + **增益写入的唯一出口**。`video_regs.h` 是偏移的唯一真源。

**关键函数**

| 函数 | 签名 | 调用者 | 副作用 | 失败 |
|---|---|---|---|---|
| `video_read` | `uint32_t (uint32_t off)` | 全部 | 一次 32 位 APB 读 | — |
| `video_write` | `void (uint32_t off, uint32_t v)` | `video_stats.c:21,22,38` | 一次 APB 写 | 无 pslverr 检查 |
| `video_probe` | `int (void)` | `camera_3a_init:38` | 读 4 个寄存器 | `-1`（ID≠`0x4f534431` 或 VER≠`0x10000` 或 CAPS 缺位 或 SOURCE≠1） |
| `video_apply_gains` | `int (uint16_t r,uint16_t g,uint16_t b)` | `camera_3a.c:63,172` | 写 0x040/044/048 → 0x050=1（capture commit） | `-1`：任一分量为 0，或 `CFG_STATUS.bit0`(cap_busy) 为 1 |

**逐行要点**
- `video_regs.h:3-48`：基底 0xf8100000 + 40 余个偏移。**与 RTL 逐项核对结果见前面自查表**；
  `0x108-0x12c`（HIST）与 `0x180-0x1a0`（AWB）在 RTL 里分别是"未解码"和"硬连 0"。
- `video_regs.h:49`：`VIDEO_REQUIRED_CAPS = (1<<3)|(1<<5)|(1<<8) = 0x128`；RTL CAPS=`0x1ff` ✓。
- `video_regs.h:54-57`：`video_stats_t`（13 个 32 位 + 1 个 64 位时间戳）。
- `video_ctrl.c:4-7`：`video_probe` 用 `&&` 链，任何一项不符即 `-1`。
- `video_ctrl.c:8-12`：`video_apply_gains`。**先查 busy 再写**，但**写完 0x050 不等 ack**（异步提交，由 0x054/0x058 轮询确认）。
  注释里的 `0x050=1` 与 `_calib_apb.py` 的联调路径一致。

**风险与疑点**
- `video_ctrl.c:9`：`cap_busy` 时**直接放弃且不重试**；调用者 `camera_3a_init:63` 又**不检查返回值** → 如果开机瞬间恰有一拍 busy，520/290/520 会静默丢失，且永不重发（只有相机重连才会重进 init）。当前开机时序下 busy 为 0，风险实际很低，**但这是"校准值可能悄悄不生效"的唯一路径**。置信度：中（静态确定，触发概率低）。
- `video_ctrl.c:10-11`：不检查 `pslverr`。写 0x050 若被 RTL 判 `value_error`（增益为 0、filter 非法、busy），会置 `fault_sticky[5]` 并置 pslverr，固件只是看不到 —— 表现在 `FAULT` 计数里，不易归因。

**文档偏差**
- `ARCHITECTURE_FULL.md:296` 写「`0x0dc STATS_CFG`（**未实现**）」—— **错**：`video_apb_ctrl.sv:103` 实现为
  `st_cfg`（= 该统计帧对应的 `cap_source_seq` 快照），而 `camera_3a.c:123` 正是拿它和
  `VIDEO_CAP_ACTIVE_SEQ` 比对来丢弃"配置切换期间"的统计帧。若真按文档当成恒 0，会得出
  "AE 每帧都被拒"的错误结论。**这条勘误建议优先处理**（会直接误导 3A 排障）。
- §十「RGB 增益映射 `video_apb_ctrl.sv:47`」：实际组合赋值在 `:52`（`:47` 是 `video_cfg_cdc` 的例化），行号略偏。

### 6. `software/firmware/video_stats.c`（39 行）

**职责**：AE 统计的"一致性读取" + 直方图轮询（死码）。

**关键函数**

| 函数 | 签名 | 调用者 | 副作用 | 失败 |
|---|---|---|---|---|
| `video_stats_read` | `int (video_stats_t *s)` | `camera_3a.c:114` | 读 12 个寄存器，最多重试 3 次 | `0` 成功；`-2` 读到但 `source!=1`；`-1` 三次 seq 都不稳 |
| `video_hist_poll` | `int (video_hist_t *h)` | `main.c:90` | 写 0x108/0x118/0x128，读 0x124/0x12c/0x11c | `1` 完成 / `0` 未完 / `-1` CAPS 无 bit6 / `-2` 状态错误 / `-3` 校验不符 |

**逐行要点**
- `2-14`：seq 前后比对（`s->seq==video_read(VIDEO_STATS_SEQ)`）保证快照一致；`source==1` 保证是"capture 域"统计。
  `time_lo/hi` 在 RTL 恒 0（`video_apb_ctrl.sv:97-98`），时间戳无意义但未被使用。
- `15-39`：直方图状态机（state 0/1/2，每次最多 4 个寄存器读，78 项 = 14 meta + 64 bin）。
  `sum==meta[1] && meta[13]==1 && (meta[8]&1)` 三重校验（设计意图不错）。
- **但 RTL 里 0x108-0x12c 一个都没有**（`video_apb_ctrl.sv` 的 case 到 0x104 就跳到 0x140），
  每次访问都会 `default: ext_legal=0` → **置 pslverr**，读回 0 → `status=0` → 状态机永远停在 state=1 的 `if(!(status&2)) return 0`。

**风险与疑点**：`main.c:11` 的 `app_hist_enable` 无任何写入点（.bss 初值 0），所以这条死路**当前不会执行**。
若有人把它置 1：每秒多 4 次 pslverr + 永远 `app_hist_errors` 不增（`rc=0` 不算错）→ 静默无效。

### 7. `software/firmware/camera_3a.c` / `.h`（201 / 23 行）

**职责**：AE/AWB 运行时（软件 3A），色彩增益注入点。在流程里：`main.c:79` 初始化一次，之后每 1 ms 被 `camera_3a_service` 调一次（内部按"统计帧变化"限速，约 18 次/秒）。

**关键函数**

| 函数 | 签名 | 调用者 | 副作用 | 失败 |
|---|---|---|---|---|
| `advanced` | `static int (uint32_t now,uint32_t old,uint32_t frames)` | 内部 | 无（有符号差值处理回绕） | — |
| `camera_3a_init` | `int (camera_3a_t*, uint64_t now)` | `main.c:79,108` | 清零状态；读 VTS/曝光/0x3802；**写 VTS=2500**；`video_apply_gains(520,290,520)`；`enabled=1` | `-1` probe / `-2` I2C / `-3` vts<8 |
| `set_exposure` | `static int (camera_3a_t*, uint32_t value)` | `:98` | 0x3812=0 持住 → 写 0x3e00/01/02 → 0x3812=0x30 释放；记录 `exposure_reserved` | `-1`（任何一步 I2C 失败，**但仍会尝试释放**） |
| `confirm_exposure` | `static int (camera_3a_t*)` | `:131` | 回读并与 `pending_exposure`/保留位比对 | `2` 读失败 / `3` 不一致 / `0` OK |
| `camera_3a_service` | `void (camera_3a_t*, uint64_t now)` | `main.c:88` | 见下；可能写曝光、写增益、置 `enabled=0` | 无返回值（状态在 `s->status/last_error`） |
| `camera_3a_log` | `void (const camera_3a_t*)` | `main.c:117` | 一行 256 B UART | — |

**`camera_ae.c`**：`camera_ae_goal(high)` = `128 - min(24,(high-10)/4)`；`camera_ae_target(cur,max,mean,high)`：
误差 >4 才动；误差 ≥24 用比例（`cur*goal/mean`，钳到 0.5×–2×）；误差 12–23 用 1/2、<12 用 1/4 步长；最后钳 `[4, maximum]`。
**`camera_awb.c`**：`smooth()` 死区 ±3、步长 /4、单次上限 ±16、范围 128–1024；
`camera_awb_target()` 守卫（`:13-14`）要求 `flags.bit4`、`64<=cells<=total`、`cells/total>5%`、且 r/g/b_sum 非零，
然后 `target = g_sum*256/(2*r_sum)`（G 含两个绿色样本）。

**逐行要点（按行号段落）**

| 行段 | 内容 |
|---|---|
| `3-8` | 校准来历注释：2026-10-25 24 色卡、室内光；RTL 默认 360/256/425 偏青；调试走 `_calib_apb.py`（写 0x040/044/048 再 0x050=1） |
| `9-16` | `STYLE_AE_FREEZE` 的两段互相矛盾的注释（先是"冻结曝光再调增益"，后是"AE 正常运行，不需要冻结"），最终 `#define STYLE_AE_FREEZE 0` |
| `18-20` | `STYLE_R/G/B_GAIN = 520/290/520` |
| `22-27` | `THREE_A_HZ`：带 BSP 时用 `BSP_CLINT_HZ`，否则 100 MHz |
| `28-31` | `CAMERA_VTS_OVERRIDE 2500`（注释：2500 行 → 约 18 fps，最大曝光 `2*2500-11=4989` 半行） |
| `32-34` | `app_awb_mode = AWB_AUTO`（默认自动 = 实际失效）；`app_3a`；`advanced()` |
| `35-44` | `camera_3a_init` 开头：整结构体逐字节清零（`volatile` 写，防优化）；`video_probe()` 失败 `-1`；读 0x320e/0x320f/0x3e00-02/0x3802，任一失败 → `status=BUS_ERROR`、`errors++`、`-2` |
| `45-46` | `vts=(h&0x7f)<<8|l`；`vts<8` → `-3` |
| `47-57` | 写 VTS：0x3812=0x00 持住 → 0x320e=(h&0x80)|高字节 → 0x320f=低字节 → 0x3812=0x30 释放。
**语义说明**：`0x3812` 是组保持（group hold）开关；这里用它把两个字节原子化，避免半个 VTS 生效。
失败时保留传感器原 VTS（`last_error=5`）。 |
| `58` | `maximum=2*vts-11`；`exposure` 从 0x3e00[3:0]+0x3e01+0x3e02[7:4] 拼 |
| `59` | `confirm_frames = 3 + (0x3802 & 3)`（0x3802 是组保持延迟，最大 3 → 3..6 帧） |
| `60-63` | **唯一的色彩增益注入点**：`video_apply_gains(520,290,520)`，**返回值被丢弃** |
| `64-65` | 记 `last_seq`，`enabled=1`，`status=READY` |
| `67-79` | `set_exposure`：读→持住→写三字节→**无论成败都释放**（`:74-75` 注释明确） |
| `80-86` | `confirm_exposure`：回读整 16 位曝光 + 保留位（0x3e00[7:4]、0x3e02[3:0]） |
| `87-93` | 服务入口：`!enabled` 直接返回；`VIDEO_FLAGS&0x26`（采集/缩放故障）→ `CAPTURE_FAULT` + `enabled=0`；1 s 无新统计 → `NO_STATS` 并清队列；曝光等待 >2 s → `CONFIG_TIMEOUT` + `enabled=0` |
| `94-102` | 曝光队列：等 `SENSOR_FRAME` 变化（跨帧边界）才写，避免撕裂；写成功则记 `pending/write_sensor/write_capture/waiting_exposure` |
| `103-111` | 增益握手等待：`CFG_STATUS.bit0` 忙则最多等 2 s；不忙则校验 `CAP_ACTIVE_SEQ`、R、B、**G==256** |
| `113-123` | 读统计（`video_stats_read`）；**丢弃 seq 未变的帧**；校验 `flags.bit0`、`samples`、`hot<=samples`、`y_sum<=samples*255`、`flags&0x26`、`cfg==CAP_ACTIVE_SEQ` |
| `124-135` | 确认增益（`waiting_gain`）；确认曝光（要求 `SENSOR_FRAME` 与 `frame` 都前进 `confirm_frames` 帧，然后回读比对） |
| `136-142` | 算 `mean`、`high_permille`、`status=READY`、`ae_goal`；`STYLE_AE_FREEZE` 分支（当前编译为空） |
| `143-157` | AE 主决策：`target==exposure` → 保持；误差 <24 且 exposure 在合法区间 → 进/出 ±4/±8 滞回 + 同向连续 3 帧确认 |
| `158-162` | 需要改曝光 → 入队 + 记 `queue_sensor`，**返回**（下一轮才真正写） |
| `163-169` | AWB 决策：`AWB_LOCK` 直接返回；`AWB_FIXED` 用 520/520（G 用 290）；否则 `AWB_AUTO` 且要求帧号前进 ≥4 帧 + `camera_awb_target()` 返回"要改" |
| `170-174` | 写增益：先查 busy，`wanted_cfg=CAP_ACTIVE_SEQ+1`，`video_apply_gains(nr,290,nb)`，置 `waiting_gain` |
| `177-198` | 日志：`3A state/exp/vts/mean/hot/goal/hold/R/B/AE/AWB/code/req/rb/err` |

**风险与疑点**

| 位置 | 为什么可疑 | 现象 | 置信度 |
|---|---|---|---|
| `camera_3a.c:109` vs `:172` | 校验常数写死 `G_ACTIVE==256`，而实际下发 `STYLE_G_GAIN=290` | AWB 一旦工作（或切 `AWB_FIXED`），第一次握手指令即判 `CONFIG_TIMEOUT` → `enabled=0`，3A 永久停摆 | **确定（静态）／当前不可达** |
| `camera_3a.c:116` | `v.hot=0` 后 `:136` 用它算 `high_permille` | UART 的 `hot` 字段**恒 0**；`camera_ae_goal` 的高光项成死逻辑（goal 恒 128） | **确定** |
| `camera_3a.c:63` | `video_apply_gains` 返回值被丢 | 若 cap_busy，校准值静默丢失且永不重试 | 中 |
| `camera_3a.c:90` | 1 s 无统计时置 `NO_STATS` 并清 `queued_exposure`，但**不 return** | 后续代码用旧状态继续跑，可能在无新统计的同一轮里做 AE/AWB 决策 | 中 |
| `camera_3a.c:91-93,105,110,132` | 多处 `enabled=0` 后**无人重新使能**（除相机重连） | 一次偶发超时 → 3A 永久离线，画面停在固定曝光/增益，只有 UART `state` 字段能看出 | 中高 |
| `camera_3a.c:31,58` | 4,989 上限由 VTS 常量决定 | 暗光下 AE 顶死、画面仍偏暗；改 `CAMERA_VTS_OVERRIDE` 即可提高，代价是帧率 | **确定** |
| `camera_3a.c:163-175` | 整段 AWB 死码（`camera_awb_target` 恒 0） | 增益只在 boot 时写一次；RTL 若被复位则永远回到 360/256/425（偏青） | **确定** |
| `camera_3a.c:59` | `confirm_frames` 依赖 0x3802，但 0x3802 不在初始化表里 | 实际取传感器默认（多半 0）→ 恒为 3 帧 | 中 |
| `camera_3a.c:47-49` | 注释说"刚释放组保持后回读可能还是旧值"，所以上限按写入值算 | 若传感器拒绝写入（例如 VTS 超限），`s->vts` 仍被改成 2500 → `maximum` 失真，AE 会一直要求超范围的曝光，且每次 `confirm_exposure` 都可能对不上 → `-1` → `enabled=0` | 中（取决于传感器是否夹取） |

**文档偏差**：`ARCHITECTURE_FULL.md:336` 说 `camera_awb.c` "因 `r_sum=0` 第一行就 return" —— 方向对，
但真正的一行是复合守卫 `camera_awb.c:13-14`（`flags.bit4`/`cells`/`total`/`r_sum`/`b_sum`/`g_sum`），
且根因在 RTL（`video_apb_ctrl.sv:119-127` 硬连 0）—— 文档把它记在"RTL 缺模块"，✅ 一致。

### 8. `software/firmware/camera_init_table.h`（172 行，165 条）

**结构（逐行）**
```c
typedef struct { uint16_t reg; uint8_t value; uint8_t readback; uint16_t delay_us; } camera_init_entry_t;   // :4
enum { CAMERA_INIT_COUNT = 165 };                                                                          // :5
static const camera_init_entry_t camera_init_table[CAMERA_INIT_COUNT] = { … };                             // :6-171
```
- 每条 6 B（`uint16+uint8+uint8+uint16`，无填充），表共 **990 B**（map 实测 0x3DE）。
- `readback` 全 165 条为 **0** → `soc_video_driver.c:206` 的回读校验分支是死码。
- `delay_us` 只有 2 条非零：`0x0100=0x00` 后 5,000 µs（`:7`）、`0x0100=0x01` 后 1,000 µs（`:151`）。

**分组规律（按寄存器页统计，实测）**

| 页 | 条数 | 作用 |
|---|---|---|
| `0x0100` | 2 | 流开关（0=停 5 ms，最后 0x01=开 1 ms） |
| `0x3000` | 4 | PLL/时钟（0x301f、0x3058/59/5a） |
| `0x3200` | 18 | 时序/窗口（0x3200–0x3213）+ 0x3250、0x3221 |
| `0x3300` | **42** | 模拟前端/增益/黑电平（最大一组：0x3301–0x331f、0x3364、0x338e–0x33fd） |
| `0x3400` | 7 | 0x349f、0x34a6–a9、0x34f8/9 |
| `0x3600` | **33** | 0x3633–0x36ec（PLL 分频/驱动能力），含 0x36e9/0x37f9 的 0x80→0x53 两次切换 |
| `0x3700` | 15 | 0x370f、0x3722/24/27、0x37b0–b4、0x37fa–fd |
| `0x3900` | 14 | 0x391f–0x393e（DVP/MIPI 输出时序） |
| `0x3e00` | 9 | **曝光**（0x3e00/01/02）、0x3e08/09（增益）、0x3e16–19 |
| `0x4500` | 3 | 0x4509、0x450d、0x4501 |
| `0x5700` | 18 | 0x5780–0x57ad（DPC/温度补偿类） |

**抽样 15 条（含关键语义）**

| # | reg | value | 说明 |
|---|---|---|---|
| 1 | `0x0100` | `0x00` | 软复位/停流，随后延 5 ms —— 整表起点 |
| 4 | `0x3058` | `0x21` | PLL 配置组（与 0x3059/0x305a 成组，值 0x21/0x53/0x40） |
| 9 | `0x3301` | `0x0c` | 模拟块起始，0x3301–0x330b 是一组斜率的成对参数 |
| 49 | `0x33fc` | `0x48` | 与 0x33fd=0x78 成对（典型为黑电平/DPC 门限） |
| 63 | `0x34f8` | `0x78` | 与 0x34f9=0x10 成对 |
| 87 | `0x36a4` | `0xf8` | 0x3696–0x36a6 是一组 8 个 0x80/0x88/0xf8 型值（PLL 环滤波） |
| 111 | `0x3933` | `0x80` | 0x3933–0x393e 输出时序块起点 |
| 116 | `0x3939` | `0x00` | 同块内多为 0x00/0x02/0x80 |
| 122 | `0x3e00` | `0x01` | 曝光高 4 位（默认 0x1bbf0>>12 = 1），与 0x3e01=0xbb、0x3e02=0xf0 组成 16 位曝光 |
| 124 | `0x3e02` | `0xf0` | 曝光低 4 位在 bit7:4；低 nibble（bit3:0）是保留位，`set_exposure` 会保住它 |
| 126 | `0x3e17` | `0xc5` | 与 0x3e16=0x00 成对（模拟增益/转换增益） |
| 147 | `0x57ac` | `0x00` | 0x5780–0x57ad 块尾部 |
| 149 | `0x36e9` | `0x53` | **PLL 解锁步骤**（0x80→0x53），紧接 0x37f9=0x53 |
| 151 | `0x0100` | `0x01` | **开流**，延 1 ms（其后的窗口/增益寄存器在开流之后才写） |
| 163 | `0x320b` | `0x38` | 窗口块尾（0x3208/09=0x0780=1920、0x320a/0b=0x0438=1080 很像输出宽高） |

**非单调复位点（4 处，实测）**：`0x37f9→0x301f`（前置头）、`0x57ad→0x36e9`、`0x37f9→0x0100`、`0x3e09→0x3221`。
说明这张表是"**四阶段**"：①停流+PLL 旁路（0x0100/0x36e9/0x37f9=0x80）→②大量模拟与 ISP 参数（0x30xx–0x57xx）→
③释放 PLL + 开流（0x36e9/0x37f9=0x53、0x0100=0x01）→④窗口/增益收尾（0x3200–0x3213、0x3e08/09、0x3221、0x4501）。

**风险与疑点**
- `:151` 开流之后还写窗口与裁剪（0x3200–0x3213）：多数 SmartSens 传感器要求窗口在停流时配置，或至少需要一次
  重新触发；当前表没有第二次停/开流，也没有用 0x3812 组保持。置信度：中（若首帧尺寸异常即可证实）。
- `readback` 全 0：初始化阶段的"写-读-比"能力形同虚设（I2C NACK 仍能抓到）。

### 9. `software/firmware/rowpipe_weights.h`（约 47 KB，456 行数据）

**结构**
```c
/* rowpipe cap8 DDR blob: output-range-fixed (v4), extracted from artifacts/soc_video_app_redsky_v4.bin. … */  // :1-2
static const unsigned int rowpipe_weights[3612] = { …8 个 word/行… };   // :4-455
#define ROWPIPE_WEIGHT_WORDS 3612u
#define ROWPIPE_WEIGHT_XOR  0xcb1d96c9u
```
- **实测**：数组 3,612 个 `0x…u` 字面量；按声明长度取前 3,612 个求 XOR = `0xcb1d96c9`，**与宏一致**。
- 3,612 word × 4 = **14,448 B** = 903 × 16 B beat。map 里 `.rodata.rowpipe_weights` = `0x3870` = 14,448 B，**逐字节对得上**。
- 数据抽样（前 4 行）：`0x2475bad5,0,0,0,0x0f1cb23c,0,0,0,…` —— 16 B beat 内只有部分字非零（打包留白），
  尾部 `0x00006f14,0x00004bc5,0xffffa5d5,0x0000662f` 与 `0x003fc026u/0x003fc025u` 是 BN/M 与量化参数段。
- 版本对照与"22,512 B"的裁决见前面**权重版本对照表**。

### 10. `software/firmware/style_selftest.h`（19 KB）

**结构**
```c
/* Integer oracle fixture, little-endian XBGR8888, 32x24. */      // :1
static const uint32_t style_test_input[768]  = { … };            // :3-99   (32*24 = 768)
static const uint32_t style_test_expected[768] = { … };          // :101-最后
```
**结论（实测）**：这两个数组**没有任何引用**（全工程 grep 只命中定义本身），链接时被 `--gc-sections` 丢弃
（map 文件里没有 `style_test_*`）。即：
- 不占固件体积（所以 `-Os` 没问题）；
- **但"INT8 RGB 自检"根本不存在**：`style_init_and_selftest()` 里没有任何比对循环，
  `app_style_selftest_errors` 也没有自增点，`-6` 不可达。
- 数据本身像是"渐变输入 + 风格化输出"的金样，注释说与 rowpipe 输出的 32×24 不一致（`style_driver.c:53-54` 已承认），
  即这套金样属于旧 Monet 网络，**对当前 rowpipe 已无意义**。

### 11. `software/firmware/style_weights.h`（76,953 B）—— 是否还被引用？

**结论：固件侧已无任何引用。**
- 全仓 grep `style_weights` 只有一处命中：`tools/package_style_demo.py:7` 把 `rtl/style/model/style_weights.h`
  拷进 app 目录（历史打包脚本）。
- 固件编译列表（`tools/build_firmware.sh:20`）不含它，9 个 .c 里也无人 `#include`。
- 它是旧 `style_network`（Monet 4×4 INT8）的系数量化表，走 `coef_*` 写口；
  当前 `USE_ROW_PIPE=1`（`style_accel.sv:3,108`）走 `style_network_rowpipe`，
  其 `coef_we/coef_addr/coef_word/coef_data` 被显式忽略（`style_network_rowpipe.sv:27,143`）。
- 也就是说：**两套权重机制并存，只有 DDR blob 那套是活的**；`style_weights.h` 属可删的死重（76 KB）。

### 12. `software/bsp/` 被引用 API 语义（只读核对）

| API | 定义 | 语义要点 |
|---|---|---|
| `uart_writeStr(reg,str)` | `uart.h:125-127` | `while(*str) uart_write(reg,*str++)`；`uart_write` 轮询 TX FIFO，**阻塞**。115200 下 120 字符 ≈ 10 ms |
| `bsp_putChar(c)` | `bsp.h:24` | 宏 → `uart_write(BSP_UART_TERMINAL,c)` |
| `bsp_init()` | `bsp.h:129-136` | 只配 UART：`clockDivider = BSP_CLINT_HZ/(BAUD*DATA_LEN)-1`（115200, 8N1，`soc.h:29-32`） |
| `clint_getTime(p)` | `clint.h`（`readReg_u32` 生成） | 读 64 位 TIME，内部处理高低字回绕；**固件所有超时的唯一时基** |
| `clint_uDelay(us,hz,p)` | `clint.h` | 忙等；`bsp_uDelay` 宏封装（`main.c:61` 的 20 ms） |
| `plic_claim/set_enable/set_priority/set_threshold/release` | `plic.h` | 标准 PLIC：claim 返回源 ID（0=无），release 必须在处理完后写；`soc.h:4` 的 `SYSTEM_PLIC_USER_INTERRUPT_A_INTERRUPT = 16` 就是 `style_accel.irq` 的 ID |
| `i2c_applyConfig/masterStart/txByte/txNack/listenAck/rxData/getMasterStatus/masterStop/masterDrop/masterRecover` | `i2c.h` | Sapphire I2C 控制器位级操作；`RX_ACK.VALID` 是**读清**（`soc_video_driver.c:46-47` 的注释与实现依赖这一点） |
| `read_u32/write_u32` | `io.h` | volatile 32 位 MMIO 读写，无 barrier（因此固件里手动插 `fence`） |

---

## 可疑代码清单（汇总）

| # | 位置 | 为什么可疑 | 现象 | 置信度 |
|---|---|---|---|---|
| 1 | `camera_3a.c:109` vs `:172` | 校验写死 `G_ACTIVE==256`，下发却是 290 | AWB 一旦生效 → 首次增益握手判超时 → `enabled=0`，3A 永久停 | **确定（静态）/当前不可达** |
| 2 | `style_driver.c:55` + `main.c:58` | `-6` 不可达；`style_selftest.h` 数据无人引用 | "INT8 RGB self-test PASS" 是空断言；像素自检从未存在 | **确定** |
| 3 | `main.c:69-75` + `soc_video_driver.c:150-161` | 对已被 RTL 删除的 OSD 页等 ACK | 开机 250 ms 停顿 + `OSD initial COMMIT timeout`；之后每秒 `OSD metrics COMMIT timeout`、`app_osd_errors` 每秒 +1 | **确定** |
| 4 | `style_driver.c:71-73` | 0x54/0x58…0x84 在 RTL 无实体 | DDR 剖面半行恒 0（假数据） | **确定** |
| 5 | `style_driver.c:86-90` + `style_network_rowpipe.sv:137-141` | `stat_*` 被 RTL 拉 0 | `RPMS/CPMS/PF/PFC/OVLP` 恒 0 | **确定** |
| 6 | `style_driver.c:114` + RTL `:24-30` | 读 legacy 窗口 0x24 | `DISP` 恒 0 | **确定** |
| 7 | `camera_3a.c:116` | 强制 `v.hot=0` | UART `hot` 恒 0，高光软化逻辑死 | **确定** |
| 8 | `camera_3a.c:163-169` + `camera_awb.c:13-14` + RTL `:119-127` | 三重原因导致 AWB 永不动作 | 增益只在 boot 写一次，颜色无法跟随光源 | **确定** |
| 9 | `camera_3a.c:91-93,105,110,132` | 多处 `enabled=0` 后无自动恢复 | 一次超时 → 3A 永久离线（画面锁死在当前曝光/增益） | 中高 |
| 10 | `camera_3a.c:63` + `video_ctrl.c:9` | apply 返回码被丢；busy 时不重试 | 校准值可能静默不生效 | 中 |
| 11 | `camera_3a.c:31,58` | 4,989 上限是常量推导 | AE 顶死、暗光偏暗；改 VTS 即可突破（与文档"硬件限制"不符） | **确定** |
| 12 | `video_stats.c:17-38` + RTL（0x108-0x12c 未解码） | 直方图寄存器不存在 | 若启用 `app_hist_enable`：每次访问 pslverr、状态机永远不完成 | **确定**（当前不可达） |
| 13 | `camera_3a.c:90` | 清队列后不 return | 无统计的同一轮仍参与决策 | 中 |
| 14 | `camera_init_table.h:151` | 开流后才写窗口寄存器 | 首帧可能是默认窗口 | 中（低） |
| 15 | `camera_init_table.h:4` `readback` 全 0 | 回读校验死码 | 初始化"写成功"未验证 | **确定** |
| 16 | `style_driver.c:42` | 用 D-cache 无效化当写回 | 逻辑上依赖未文档化语义；万一语义不同会 `-3` 卡启动 | 中（低） |
| 17 | `start.S:65-68,100-101` | 非 MEI 异常静默停机 | 现场表现为"无故卡死"，无 UART 线索 | 中（低） |
| 18 | `app.h`-无关：`main.c:47-50` | DDR 自检失败直接 `for(;;)` | 无重试、无复位 | **确定**（设计选择） |

---

## 未提交改动的逐块解读（git diff）

当前分支 `feature/colour-calib-redsky-q`，HEAD = `5dfaf5a feat(style): redsky_q weights and a calibrated colour balance`。
`git status` 里 `software/firmware/` 有两个文件改动；其中 `camera_3a.c` 是 **`MM`（暂存区 + 工作区都有改动）**，
所以"新增 32 行"是**未暂存那部分的数字**，不是相对 HEAD 的净改动。

### 块 1：`camera_3a.c` 未暂存部分（32 增 1 删）—— 其实是"把已提交的校准再加回来 + 冻结开关"

```diff
+#define STYLE_AE_FREEZE 0
 #define STYLE_R_GAIN 520u    /* 这 3 行 HEAD 里就有，未暂存段只是"重新出现" */
-if(app_awb_mode==AWB_FIXED) {nr=0x168;nb=0x1a9;…}
+if(app_awb_mode==AWB_FIXED) {nr=STYLE_R_GAIN;nb=STYLE_B_GAIN;…}
-if(video_apply_gains(nr,256,nb))return;
+if(video_apply_gains(nr,STYLE_G_GAIN,nb))return;
```

### 块 2：`camera_3a.c` 暂存部分（2 增 16 删）—— 把校准**撤掉**（还原成 RTL 默认 0x168/0x1a9/256）

**逐块说明**

| 块 | 内容 | 行为影响 |
|---|---|---|
| A（未暂存，`+`12 行注释 + `STYLE_AE_FREEZE 0`） | 两段互相矛盾的注释 + 冻结开关 | **无行为影响**（`#if STYLE_AE_FREEZE` 为 0，`s->ae_held=1; return;` 不编译进去） |
| B（未暂存，`#if STYLE_AE_FREEZE … #endif`，5 行） | AE 冻结分支 | 同上，**死代码** |
| C（未暂存，`AWB_FIXED` 两个分支由字面量改成宏） | `0x168/0x1a9` → `STYLE_R/B_GAIN`；`256` → `STYLE_G_GAIN` | **无行为影响**（宏值 520/520/290 与暂存版的 0x168=360/0x1a9=425/256 不同，但该分支不可达；真正生效的是 `:63` 的 boot 注入） |
| D（暂存，删 3 个 `#define STYLE_*` + 删 `video_apply_gains(...)` 调用 + 把宏换成字面量） | 把校准整段**回退** | **有行为影响**：`camera_3a_init` 不再写 520/290/520，颜色回到 RTL 默认 360/256/425（偏青） |

**净效果（`git diff HEAD`）**：只有 **10 行新增**，即 `STYLE_AE_FREEZE` 的注释 + 宏 + `#if` 块，
**`STYLE_AE_FREEZE=0` 使它对运行时零影响**。也就是说：

> **相对于 HEAD，`camera_3a.c` 的行为没有变化；520/290/520 的校准和 `video_apply_gains()` 调用在 HEAD 里就已经存在。**
> "32 行新增"是"暂存区把校准撤了、工作区又加回来"的假象，容易让人误以为这次改动引入了色彩校准。
> 真正需要核对的是：**要提交时应该提交工作区版本（保留校准），而不是暂存区版本（丢掉校准）。**

### 块 3：`rowpipe_weights.h`（46 增 46 删）—— 从 redsky_q 切到 redsky_v4

| 项 | HEAD (`redsky_q`) | 工作区 (`redsky_v4`) |
|---|---|---|
| 头注释 | `/* rowpipe cap8 DDR blob: 903 beats = 14448 bytes; layout per README */` + `/* redsky_q variant … */` | `/* output-range-fixed (v4), extracted from artifacts/soc_video_app_redsky_v4.bin … OUTPUT_RANGE_FIX_DONE.md */` |
| `ROWPIPE_WEIGHT_XOR` | `0xc06d273c` | **`0xcb1d96c9`** |
| 变化字（实测逐 word 比对） | — | **183 / 3,612 word 不同（5.1%）**，分散在 **77 个连续段**内，最早 [124]，最后 [3608] |
| 变化形态 | — | 集中在 BN/M/量化参数位置（如 [124]、[304-311]、[644-651]、[1340-1355] 等成段出现），首/末偏移与"输出量程修正"的描述吻合 |
| 字节数 | 14,448 | 14,448（不变） |

**行为影响**：换的是"值"不是"结构" —— 层偏移表、beat 数、数组长度全部不变，所以
`style_init_and_selftest()` 的装载量与 XOR 校验都自洽（改后 XOR 与宏一致，实测已验）。
板上效果见 `OUTPUT_RANGE_BOARD_VERIFY.md`：DDR σ 13–15 → **33–37**（量程修好），但空间平坦度仍差（另一问题）。

**提交建议**：这两个文件应当**一起**提交（权重换 v4 + 校准保留），并顺手把
`style_driver.c:38-39` 的 "22,512 B / 1,407 beat" 注释改成 "14,448 B / 903 beat"。

---

## 给 Lead 的 5 条要点

1. **权重尺寸的悬念已解决，且是"文档错、代码对"。**
   当前 RTL（`style_network_rowpipe.sv:79-92` 的 12 层 `DESCS` + `rowpipe_engine.v:242-259` 的 `wbase_of`）
   对权重 blob 的需求恰好是 `40+49+9×85+49 = 903` beat = **14,448 B**，与头文件 3,612 word 完全对应，
   map 里 `.rodata.rowpipe_weights` 也是 14,448 B。22,512 B / 1,407 beat 出自 `model/weights_blob_D_sw1e5_640.bin`
   （L11 段 553 beat 的旧导出，与任何现有头文件都不逐字相同）。
   **建议把 `style_driver.c:38-39`、`ARCHITECTURE_FULL.md:175/261/339`、`MODEL_OUTPUT_RANGE_FIX.md:67` 一起勘误**，
   否则每次读代码都要重新怀疑"是不是少写了 8 KB"。

2. **发现一处确定的潜伏 bug（唯一改代码就能修的那种）**：`camera_3a.c:109` 校验 `G_ACTIVE==256`，
   而 `camera_3a.c:172` 下发 `STYLE_G_GAIN=290`。现在因为 AWB 彻底失效这条路径不可达；
   一旦 RTL 补上 AWB 统计、或有人把 `app_awb_mode` 改成 `AWB_FIXED`，第一次增益握手就会
   `status=6 / enabled=0`，**3A 会"看起来突然死掉"且不会自愈**。修法：把 256 换成 `STYLE_G_GAIN`。

3. **"AE 顶到 4989"不是硬件极限，是固件常量。** `camera_3a.c:31` 的 `CAMERA_VTS_OVERRIDE=2500`
   经 `:58` 的 `2*vts-11` 推出上限；提到 5000 就变成 9,989（帧率按比例下降）。
   如果目标是"暗光更亮"，这条比动增益便宜得多，也解释了为什么 520/290/520 在暗光下会过曝、
   在亮场景又压不住 —— **AE 与增益本来就该一起重标**。

4. **遥测有一半是假数据，排障时不要被它误导。** 恒 0 的字段：
   `DDR100M T/AR/DOWN/RGAP/…/DRB`（0x54、0x58-0x84 在 RTL 无实体，`style_ddr_profiler` 从未实例化）、
   `RPMS/CPMS/PF/PFC/OVLP`（`style_network_rowpipe.sv:137-141` 把 `stat_*` 拉 0）、
   `DISP`（读 legacy 窗口 0xf8100024）、`hot`（`camera_3a.c:116` 强制置 0）、
   `AWB` 计数（永不加）。**真正可信的是**：`VIDEO UF/DUF/DDROP/FAULT/CSI/DME/IERR/AXI`、
   `CAP/NN/DROP/MS/ERR`、以及 style 区 0x38/3c/40/44/4c/50。

5. **固件与 RTL 已经出现"代码对着已删除硬件的接口说话"的系统性不同步，建议单开一条清理线**：
   ① OSD 文本页（`soc_video_driver.c:148-186` + `main.c:69,115`）在 RTL 已被删除（`video_apb_ctrl.sv:24-30`
   把 legacy 当黑洞、`o_video_ready` 硬连 1），导致开机 250 ms 停顿 + 每秒一条超时错误；
   ② 直方图寄存器块 0x108-0x12c 在 RTL 完全未解码，`video_hist_poll` 若被启用会不断触发 pslverr 且永不完成；
   ③ `style_weights.h`（76 KB，旧 Monet 系数）与 `style_selftest.h`（6 KB 金样，已被 gc 掉）都是死重，
   前者可删、后者要么补上真比对要么删掉并改成诚实的日志；
   ④ 顺手删掉 `-6` 死返回码与 `app_hist_enable` 死开关，减少"看起来有自检"的错觉。
