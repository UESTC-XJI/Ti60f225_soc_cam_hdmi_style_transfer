# RTL统一配置与Gamma移除

起点版本在`feature/highlight-detail`独立工作区中，删除原Gamma实现、曲线文件、测试目录、工程引用和Debugger的`gamma_sel`。视频输出链路现在为：DDR读出 → 调色 → 暗部/中间调提亮 → 信息叠加 → HDMI编码。提亮后的显示测光与直方图输入仍是叠加前图像源；Gamma移除不会旁路提亮功能。

当前工程入口改用`ti60f225_cam_hdmi.xml`。原`ti60f225_oob.xml`曾被运行中的旧工程状态反复写回含Gamma的源文件列表，因此另存独立配置。请先关闭Efinity中已打开的旧工程，再打开新XML；项目名仍为`ti60f225_oob`，输出仍是`outflow/ti60f225_oob.bit`，接口和SDC文件路径保持一致。

命令行编译：`C:/Efinity/2026.1/bin/efx_run.bat ti60f225_cam_hdmi.xml --flow compile --timeout 1200`。

## 配置入口

统一入口为`rtl/defines.v`，带头文件保护。每个可编辑RTL通过相对路径引用同一个文件，Efinity无需另设头文件搜索路径。Icarus使用`-grelative-include`，已写入回归脚本。

文件前部保留DDR原有宏名称，随后为固定范围定义，其余按源文件路径分组：

| 宏类型 | 内容 | 示例 |
| --- | --- | --- |
| 原DDR宏 | DDR几何、时序、AXI位宽 | `AXI_DATA_WIDTH`、`DQ_WIDTH`、`tRCD` |
| `CFG_BITS_N` | N位固定范围，使用为`[宏-1:0]` | `CFG_BITS_8` |
| `CFG_RANGE_A_B` | 固定数组或总线范围A:B | `CFG_RANGE_0_63` |
| `CFG_路径_PARAMETER_名字` | 模块参数默认值 | `CFG_ISP_HDMI_FRAME_HISTOGRAM_V_PARAMETER_FRAME_WIDTH` |
| `CFG_路径_LOCALPARAM_名字` | 局部常量及派生表达式 | `CFG_TI60F225_OOB_TOP_V_LOCALPARAM_HACT` |
| `CFG_路径_INST_实例_参数` | 指定例化覆盖值 | `CFG_TI60F225_OOB_TOP_V_INST_AE_METER_FULL_FRAME_MEAN` |
| `CFG_路径_RANGE_序号` | 声明中的派生位宽/数组范围 | `DATA_WIDTH-1:0`原表达式在宏中保留 |

模块的`parameter`接口保留，测试及复用时仍可通过`#(...)`覆盖参数。派生宏在使用模块的作用域展开：例如`DATA_WIDTH-1:0`仍使用该实例的`DATA_WIDTH`，不会被固化为顶层宽度。原来的逗号参数声明、命名/位置例化、函数返回值、端口/信号/数组范围均纳入整理。

固定宽度宏表示协议和计算位数，并非可任意调节的独立功能参数。修改位宽还需要同步核对位选、定点格式、常量、CDC消息布局、Debugger探针和IP端口；这些位选及运算常量保持原语义。当前720p显示时序在`CFG_TI60F225_OOB_TOP_V_LOCALPARAM_HACT/VACT/HFP/HSP/HBP/VFP/VSP/VBP`，源尺寸另由`SOURCE_WIDTH/SOURCE_HEIGHT`宏设为1920×1080；帧缓存写入每拍两像素、64位、640拍/行，读出32位、1280拍/行，修改分辨率必须一并核对。

## 覆盖范围

当前覆盖`rtl/`下105个可编辑Verilog/SystemVerilog文件（包含新加入的两个缩放源文件）。起点版本覆盖103个文件，包含DDR控制器的明文外壳、原例程、SoC预留模块及RTL目录中的测试例程。起点迁移4,265处参数、例化和派生范围表达式，以及1,465处固定范围；详细逐文件清单见`tools/rtl_config_manifest.json`。

`rtl/ddr3_controller/ddr3_parameter.vh`成为兼容引用入口，DDR宏的数值只在`defines.v`维护。厂商加密块不变，其明文端口/参数外壳及工程外部例化配置已整理。IP生成器的局部UUID/名称拼接宏保持原位置。`ip/`下未被当前工程编译的生成副本和例化模板、Efinity生成的`debug_top.v`由对应工具维护，不作为手写配置入口；重新生成厂商IP并覆盖`rtl/`时需重新迁移该外壳配置。

提亮查表头文件由`tools/generate_lift_tables.py`维护，生成器已同步使用统一宽度宏，重新生成不会恢复旧的声明位宽写法。

## 验证

`tools/check_rtl_config.py`检查105个RTL文件：本次9个有意迁入的720p文件，在宏展开后核对迁移前代码token的SHA-256；其余96个文件及DDR/加密内容继续对照原迁移基线`748553b`。功能迁入的token指纹记录在`tools/rtl_config_manifest.json`，不能把正常720p功能变化误判为宏迁移误改。

`tools/centralize_rtl_config.py`保留为一次性迁移记录，不应在已有`defines.v`的工程反复运行。日常修改直接编辑`defines.v`，并运行`python tools/run_rtl_checks.py`；工具路径可通过回归脚本环境变量配置。宏本身不产生硬件，资源变化主要来自Gamma和对应Debugger控制删除。

完整Efinity资源与时序验证见`../reports/archive/legacy-documents/720p-pre-soc_RESOURCE_USAGE_REPORT.md`；实际显示效果仍需下载新bitstream并使用配套`debug.json`确认。

`tools/refresh_rtl_config.py`用于选择性迁入仍含原始参数/位宽的明文RTL，临时生成宏后合并对应文件章节，并先核对展开token。不要直接对已经宏化的RTL重复运行；日常修改直接编辑`defines.v`并按有意功能变更更新审计指纹。720p迁入文件共重新迁移331处表达式、218处固定范围。
