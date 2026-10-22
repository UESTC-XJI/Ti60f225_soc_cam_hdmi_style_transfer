# 基线备份清单

基线提交：`3ab82f8319c8f12284078f6373327093e50bb40e`

本工作区由 Git worktree 从该提交直接检出。以下类别在工作区中保存并受版本控制：

- `rtl/`：摄像头 CSI、Debayer、缩放、frame buffer、DDR3、CVO、ISP、DVI/HDMI 和复位 RTL。
- `*.xml`：Efinity 工程、IP 实例及调试配置。
- `*.peri.xml`：外设和引脚数据库。
- `*.sdc`：时钟和时序约束。
- `ip/`：CSI/DSI 等 IP 生成设置及模板。
- `tests/`、`tools/`：已有仿真 testbench 和回归脚本。

可复现资料由以下命令生成/检查：

```powershell
git ls-files > docs/baseline-tracked-files.txt
git show --stat --oneline 3ab82f8319c8f12284078f6373327093e50bb40e
```

原工程报告中记录的可用烧录文件为 `outflow/ti60f225_oob.bit`；由于本轮只做仿真，该文件只作为基线证据，不作为本轮验收依据。

