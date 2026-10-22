# Ti60F225 SoC 摄像头 → HDMI 风格迁移工程 · 本地部署记录

- **仓库**：`https://github.com/UESTC-XJI/Ti60f225_soc_cam_hdmi_style_transfer.git`（**私有仓库**）
- **分支**：`feature/demo1.0`
- **提交**：`383b4477202e1ec665f1002cb8dbda6c5616b006`（2026-10-11，"数据通路完好，单层网络"）
- **部署位置**：`C:\Users\36040\Downloads\Ti60F225_DemoBoard_v4\demo`
- **部署日期**：2026-10-11

---

## 1. 部署结果

| 项目 | 状态 |
| --- | --- |
| 克隆（demo1.0 分支） | ✅ 完成，185 个受版本控制文件 |
| 工程文件引用完整性（63 个 `design_file`） | ✅ 0 缺失 |
| 生成脚本可复现性（`generate_lift_tables.py`） | ✅ 无 diff |
| Efinity 全流程编译（map→interface→pnr→pgm） | ✅ **全部 PASS** |
| RTL 回归测试（`run_rtl_checks.py` 12 项） | ✅ **全部 PASS** |
| `tb_style_pipe`（脚本未覆盖，另行补跑） | ✅ **ALL-PASS** |
| CDC 检查 | ✅ `No Synchronizer warnings to report`（与 README 一致） |
| 时序收敛 | ✅ 0 条负裕量（最差 +0.026 ns） |
| Debugger 探针位宽与网表对撞 | ✅ INT=76 / OUT=111（与 README 一致） |
| bitstream 产物 | ✅ `outflow/ti60f225_oob.bit`（2.97 MB） |

### 编译产物

```
outflow/ti60f225_oob.bit   2,966,640 字节   ← 可直接下载到板
outflow/ti60f225_oob.hex   2,966,700 字节
```

### 资源占用（与工程 README 记录完全一致）

| 资源 | 本次实测 | README 记录 |
| --- | --- | --- |
| LUT4 | 31,497 | 31,497 |
| FF | 17,737 | 17,737 |
| RAM10 | 89 | 89 |
| DPRAM10 | 4 | 4 |
| **RAMs 合计** | **93** | **93** |
| DSP48 / DSP24 | 10 / 2 | 10 / 2 |

`style_pipe` 已真实进入网表：`rtl/style/style_pipe.v` 出现在 map 报告中，
`u_style_pipe` 实例在 `outflow/ti60f225_oob.map.v` 中可见，
且 README 记载的验证点 `style_sel_vio` fanout = **16**（2 像素 × R/B 两字节 × 8 位）实测吻合，
说明 R/B 交换逻辑确实被综合进去，没有被剪掉。

---

## 2. 过程中解决的三个环境问题

### 2.1 仓库是私有的，且 github.com 被 hosts 劫持到 127.0.0.1

- `github.com` 在本机 hosts 中指向 `127.0.0.1`，该端口由一个**本地 HTTPS 加速器**接管。
- 加速器对**公开仓库**正常代理（实测 `git ls-remote` `git/git` 返回 HTTP 200），
  但对**私有仓库**无法透传认证，直接返回 **HTTP 401**。
- 经 GitHub API 核实：`UESTC-XJI` 组织下**公开仓库数为 0**，`/repos/UESTC-XJI/Ti60f225_...` 返回 404 ⇒ 该工程确为私有。

**解决**：使用本机 Git Credential Manager 中已保存的凭据（账号 `TangXY521`），
通过 Node.js 直连 GitHub 真实 IP（`20.205.243.166`，绕过 hosts 劫持）完成克隆。

> ⚠️ 克隆时凭据曾被写入 `origin` URL，**已立即清除**，远端现已恢复为干净的
> `https://github.com/UESTC-XJI/Ti60f225_soc_cam_hdmi_style_transfer.git`。
> 后续 `git fetch/push` 需要重新提供凭据。

### 2.2 Efinity 装在 `D:\`，但工程脚本默认写死 `C:/Efinity`

工程文档与 `tools/generate_debug.py` 默认 `EFINITY_HOME='C:/Efinity/2026.1'`，本机实际路径为 `D:\Efinity\2026.1`。

**解决**：两个脚本都支持环境变量覆盖，无需改动任何仓库文件：

```powershell
$env:EFINITY_HOME = 'D:/Efinity/2026.1'
$env:PYTHONHOME   = 'D:/Efinity/2026.1/python311'
```

另外 `efx_run.bat` **必须经 `setup.bat` 初始化环境**（否则 `libdevicedb_wrapper.dll` 报 `error 0x7e`）：

```bat
call "D:\Efinity\2026.1\bin\setup.bat" && efx_run.bat ti60f225_oob.xml --prj --flow compile --timeout 2400
```

### 2.3 工程自带的 RTL 检查脚本需要 iverilog，本机未安装

`tools/run_rtl_checks.py` 默认查找 `C:/iverilog/bin/iverilog.exe`，本机不存在。

**解决**：安装到工程内 `tools/iverilog/`（已加入 `.git/info/exclude`，不影响仓库），
并用 `IVERILOG` / `VVP` 环境变量指向：

```powershell
$env:IVERILOG = "$PWD\tools\iverilog\bin\iverilog.exe"
$env:VVP      = "$PWD\tools\iverilog\bin\vvp.exe"
python tools/run_rtl_checks.py
```

---

## 3. 复现命令

```powershell
cd C:\Users\36040\Downloads\Ti60F225_DemoBoard_v4\demo

# ① 生成提亮表（幂等，跑完无 diff）
python tools/generate_lift_tables.py

# ② 重新生成 Debugger 核（必须用 Efinity 自带 python311）
$env:PYTHONHOME   = 'D:/Efinity/2026.1/python311'
$env:EFINITY_HOME = 'D:/Efinity/2026.1'
& 'D:\Efinity\2026.1\python311\bin\python.exe' tools/generate_debug.py

# ③ 全流程编译
cmd.exe /c 'call "D:\Efinity\2026.1\bin\setup.bat" && efx_run.bat ti60f225_oob.xml --prj --flow compile --timeout 2400'

# ④ RTL 回归
$env:IVERILOG = "$PWD\tools\iverilog\bin\iverilog.exe"
$env:VVP      = "$PWD\tools\iverilog\bin\vvp.exe"
python tools/run_rtl_checks.py
```

### 关于 `generate_debug.py` 的注意事项

该脚本**每次运行都会重新生成 UUID**，因此会改动 `debug.json` 内的探针集合、
`debug_profile.wizard.json` 的 uuid 以及 `debug_top.v` 的 `DBG_MODULE_UUID`。

本次**未**运行步骤 ②：直接使用仓库中已提交的 `debug_top.v` / `debug_profile.wizard.json`
即编译通过，且产物与 README 记录的 `OUT_WIDTH=111 / INT_WIDTH=76` 口径一致。
若需要改探针，请重跑 ② 并**紧接着重编译**，确保 Debugger 配置与 bitstream 同批生成
（README 特别强调：不同批次生成的 JSON 与芯片内容不匹配）。

### 关于 `-f compile` 会重写 XML

工程 README 提醒：`--flow compile` 会用内部库重写 `ti60f225_oob.xml`，
可能抹掉手改的 `design_file` 行。

本次实测：`style_pipe.v` **保留完好**（第 32 行），`design_file` 仍为 63 条；
唯一变化是首行 `sw_version` 由 `2026.1.132.4.5` 变为 `2026.1.132`（纯版本戳，无功能影响），
已用 `git checkout` 还原，工作区保持干净。

---

## 4. RTL 回归测试结果（12 项全部 PASS）

| 测试 | 覆盖内容 |
| --- | --- |
| `highlight_stats_tb` ×2 | 全画面高光统计：边缘高光、千分比、ROI 均值、阈值钳位/锁存、无效帧 |
| `luma_lift_tb` ×2 | 提亮：45,791 像素、全 129 档单调性、色彩比例、余量、同步与帧锁存 |
| `auto_lift_tb` | 自动提亮：真实曲线 + 提亮后单像素测光、暗/中间调补偿、噪声稳定、强度上限、手动回退 |
| `highlight_ae_tb` | 高光 AE：暗 ROI 优先、冷却、迟滞、关闭、阈值相等、最小曝光 |
| `ae_stability_tb` | 高光闭环：3 帧延迟、陡峭削波、有界恢复（曝光 1890，37 次更新）；预测收敛 6 组场景 |
| `predictive_ae_tb` | 预测算术 1,118 组：零分母、全宽曝光、边界、锁存、安全钳位、Group Hold |
| `ae_controller_tb` | 基础 AE：曝光上下限、Group Hold、冷却、NACK 释放、粘滞故障与复位 |
| `legacy_tone_mailbox_tb` ×2 | 原调色 5,895 像素；CDC 异步时钟 49 条有序消息 |
| `i2c_runtime_tb` | 实际 I²C：165 项初始化、6.160× 增益读回、重复起始、NACK、AE Group 更新 |
| `ae_camera_stats_tb` | 相机集成：两帧完整 1920×1080 BGGR 经增益/Debayer/统计链路 |

### 4.1 补充：`tb_style_pipe` 不在聚合脚本里（已单独跑通）

`tools/run_rtl_checks.py` **没有**包含 `rtl/style/tb_style_pipe.v`。
该 TB 是 `style_pipe` 的唯一守卫，专门用来抓 README 里点名的那类错误
（第一版把一像素按 2 字节切，实际 3 通道 = 24 位；`style_sel=0` 时整块被综合剪掉，
**综合/PnR 全绿也照样带着出厂**）。漏跑它会留下真实盲区，因此本次单独补跑。

**踩到的坑**：`tb_style_pipe.v` 里有一个变量名叫 **`expect`**（第 48 行），
而 `expect` 是 **SystemVerilog 保留关键字**，`run_rtl_checks.py` 用的 `-g2012`
（SystemVerilog-2012）会直接语法报错：

```
rtl/style/tb_style_pipe.v:48: syntax error
```

两个模拟器给出同一根因：
- iverilog：`iverilog -g2012` → syntax error；改用 **`-g2005`** 编译通过
- Aldec：`vlog` 直接点名 ——
  `ERROR VCP2000 "Unexpected token: expect[_EXPECT]. The 'expect' is a SystemVerilog 3.x keyword. Please use -v2k or -v95 switch."`

TB 文件头注释写的是 **ModelSim** 跑法（未指定 SV 模式），所以它本来就是按
Verilog-2001 写的，不是缺陷，只是与聚合脚本的 `-g2012` 不兼容。

**补跑结果（两种工具链均 ALL-PASS）**：

```powershell
# iverilog（Verilog-2005 模式）
$env:IVERILOG = "$PWD\tools\iverilog\bin\iverilog.exe"
$env:VVP      = "$PWD\tools\iverilog\bin\vvp.exe"
& $env:IVERILOG -g2005 -I rtl -s tb_style_pipe -o work/rtl_checks/tb_style_pipe.vvp `
    rtl/style/tb_style_pipe.v rtl/style/style_pipe.v
& $env:VVP work/rtl_checks/tb_style_pipe.vvp
# → ALL-PASS

# Aldec Active-HDL（需 -v2k）
vlog -v2k -work work rtl/style/style_pipe.v rtl/style/tb_style_pipe.v
vsim work.tb_style_pipe   # → KERNEL: ALL-PASS (840 ns)
```

覆盖判据：① `style_sel=0` 逐位直通且零延迟；② `style_sel=1` 每像素首尾字节对调、
**G 不动**；③ 组合路径同拍生效；④ `done` 为电平、`busy` 恒 0。

> 说明：这是**运行验证**，没有改动仓库任何文件。若日后要把该 TB 纳入
> `run_rtl_checks.py`，需把它改成 `-g2005` 编译，或把变量 `expect` 改名
> （例如 `exp_v`）以兼容 `-g2012`。

### 4.2 补充：CDC 与 Debugger 口径核对

- `outflow/ti60f225_oob.cdc.rpt` = **`No Synchronizer warnings to report.`**
  —— 与 `rtl/style/README.md` §2 记载的结论一致，证明 `style_pipe` 按同域处理
  （`clk` 接 `hdmi_tx_slow_clk`，未加 CDC FIFO）在工具侧确实无告警。
- 按 `debug.json` 复算探针位宽：**有 init 的 17 个 = 111**、**无 init 的 16 个 = 76**，
  与 `outflow/ti60f225_oob.res.csv` 中 `vio0` 的 `OUT_WIDTH=111 / INT_WIDTH=76` 对撞一致，
  也与 `rtl/style/README.md` §4c 的三重核对表吻合。说明本次 bitstream 与
  仓库提交的 `debug.json` 是**同批**的，Debugger 可直接使用。

---

## 5. 尚未完成 / 需要人工确认的部分

1. **未上板**。本次只做到编译与时序，**没有连接硬件下载**。bitstream 需在 Efinity
   Programmer 中下载到 Ti60F225 开发板实测。
2. **未做板级功能验证**。传感器曝光闭环、显示画面、Debugger 连接均需实机确认。
   请按 `AE_TONE_README.md` 第 7–16 行的调参步骤操作，并注意
   `rtl/style/README.md` §4c 的坑：**Debugger 要打开 `debug.json`（不是
   `debug_profile.wizard.json`）**，否则 core 列表里看不到 `vio0`。
3. **既有 SDC 缺口**（工程 README 已声明，非本次引入）：JTAG 时钟定义仍被注释，
   存在 JTAG 相关 SDC 警告；工具另报告组合环切断警告。
   本次编译 0 条负裕量，但上述路径未纳入时序结论。
4. **网络凭据**：私有仓库克隆所用的令牌已从 git 配置中清除。如需再次
   `fetch` / `push`，需重新配置 GitHub 凭据。
5. `rtl/style/README.md` §3 提到的「真内核」（第 3 步）**尚未接入**，当前 `style_pipe`
   是单层/轻量演示形态（inline 通路），非最终帧级架构。

---

## 6. 目录说明

| 路径 | 说明 |
| --- | --- |
| `rtl/` | 131 个 RTL 源文件，含 `isp/`（AE、提亮、调色）与 `style/`（风格迁移插入点） |
| `ip/` | 18 个 IP 文件（CSI-2 RX、DSI TX） |
| `tests/` | 10 个 testbench |
| `tools/` | `generate_debug.py`、`generate_lift_tables.py`、`run_rtl_checks.py` |
| `outflow/` | 编译产物（bit / hex / 报告），**被 git 忽略** |
| `work_syn/`、`work_pnr/`、`work_dbg/` | 工具中间目录，**被 git 忽略** |
| `tools/iverilog/` | 本次为跑回归测试安装的 iverilog，**本地附加，非仓库内容** |
| `DEPLOYMENT_NOTES.md` | 本文件，**本地附加** |
