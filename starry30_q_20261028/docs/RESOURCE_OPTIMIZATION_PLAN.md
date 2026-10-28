# Ti60F225 SoC资源优化方案

修订：2026-10-12。当前范围为P1/P2/P3实施、仿真及离线FPGA编译；没有开发板连接，不下载，不讨论加速器设计。

## 1. 资源基线

最近归档完整构建为2026-10-09 reports/soc_cleanup，Efinity 2026.1.132：

| 资源 | 使用 | 总量 | 占用率 |
| --- | ---: | ---: | ---: |
| XLR | 54,993 | 60,800 | 90.45% |
| 存储块 | 147 | 256 | 57.42% |
| DSP | 19 | 160 | 11.88% |
| GBUF | 18 | 32 | 56.25% |

顶层和接口已与该归档不同，统计/APB/OSD仍与归档manifest一致。本轮已保存修改前输入并重新完成当前基线构建：55,159 XLR（90.72%）、147存储块、19 DSP。下文验收使用这次同工具、同约束的基线，证据放在reports/resource_optimization/。原54,976 XLR来自10月8日，不作为新结果。

原层次报告用于定位：video_apb_ctrl 19,899.5 XLR，其中capture_statistics 12,047.5、自身6,820.5；显示直方图3,585；OSD文字2,874；自动Debugger1,467。父子层次不能重复相加，LUT与FF也不能直接相加代替物理XLR。

## 2. P1：统计和字符数组映射BRAM

SYN-0657证实hist/frozen_hist、hist_cache、counts/heights因异步复位写入展开为逻辑，previous_row和page_mem因异步读展开为逻辑。

### 采集统计

- hist/frozen_hist合并为128x16双bank RAM，统计端口及冻结读端口都同步读，无数组复位或整表复制。
- 64位有效掩码表示活动bank尚未写入的bin为0，帧起始只清掩码；冻结时复制掩码并切换bank。这样不依赖64拍消隐扫描，也可处理启动和短VS。
- 每8拍采样一对RGB，状态机串行读两个bin，溢出检查通过后写回；同bin一次+2。帧尾未完成流水时拒绝发布。
- 冻结bank传完78字前不得覆盖；ready为0时字索引和数据保持，另一bank继续产生实时统计。
- frozen_meta保留独立冻结副本。实时packet/stats_data会更新，不能直接替代冻结META。
- previous_row同步读，当前RAW和有效标志延迟一拍，与前一行数据对齐，保留AWB过滤、密度和帧标签。

### APB

- hist_cache改64x16同步RAM，32位APB返回高16位0。保留INDEX/DATA、锁定、错误响应和78字完整性检查。
- 合法APB先写INDEX再读DATA提供同步读准备时间，保持pready=1，覆盖无空闲周期连续传输。
- hist_meta仍为寄存器：有0x110/0x114/0x120直接读和完成时同拍写两个时间戳，不套用单端口RAM模板。
- 保留scalar副本，令数据/seq/time同拍发布；直接暴露mailbox输出会比seq更新早一拍。
- 保留ACTIVE镜像；camera_3a.c实际读取R/G/B ACTIVE和ACTIVE_SEQ。

### 显示直方图

- counts/heights同步RAM，无数组复位；有效掩码屏蔽启动/清空后的未知内容。
- 16拍采样间隔内读改写，峰值扫描和bin加载等待同步读，保留24拍共享除法及归一化公式。
- 叠加层提前提供下一像素bin，维持两拍RGB/DE/HS/VS延迟；逐像素验证边界。
- mode变化、残帧及处理跨下一帧时仍不得发布错误快照。

### 文字OSD

- 字符页改双时钟同步读RAM，保留bitstream初始化的HELLO SOC。
- 字符RAM加字库ROM形成两级读流水，RGB/DE/HS/VS、行列、使能、颜色一起对齐，输出延迟三拍。
- 保留COMMIT/ACK、活动页写保护、VS边界使能和关闭期间提交；增加逐像素字形与同步检查。

## 3. P2：关闭自动视频Debugger

发布工程关闭auto_instantiation及enable-mark-debug，保留旧debug_profile.wizard.json用于恢复探针。Sapphire USER1/JTAG及CPU DEBUG保留。核对自动edb_top实例消失、CPU接口及CSI错误寄存器0x15c不变。历史1,467 XLR/1存储块仅作参考。

## 4. P3：只保留RAW10解包

实际编译rtl副本的实例PACK_TYPE=15，而IP配置只开启Pack_40。将defines.v中的实例覆盖改为1，其他IP参数、CRC/ECC、错误输出与厂商受保护块保持原样。

Icarus不能执行厂商加密CSI IP。检查配置和受保护字节，验证可执行RAW10输入与后级处理，并由Efinity综合确认48/56/64位解包器消失；不把gearbox测试称为完整CSI协议仿真。物理MIPI待上板。

## 5. 本轮不实施

- P4除9改常数乘法：公式对数学输入0..4095成立，RTL仍需明确扩位、输出范围和原四拍延迟，本轮不改。
- P5保留GPIO0（可复用为两位旋钮和两按钮）、SPI0（独立启动）、UART0、I2C0、cache、乘除法及CPU DEBUG。CPU/DDR同源可研究去掉冗余跨时钟桥，但必须重生成IP并做DDR回归，本轮不改SoC。
- P6不缩小视频FIFO、不修改speed综合模式。
- 当前顶层已经注释移除LCD端口，接口无对应约束；旧扩展方案的LCD冲突描述已过时。本轮不增加扩展板外设。

## 6. 验收与实际结果

撤销原P1节省17..19k、最终约55%占用的数值承诺。RAM块数取决于端口、位宽和映射，最终以同工具同约束的新构建为准。

1. 保存当前基线输入、资源和时序。
2. 统一APB/真实Debayer小帧和完整1080p：AE/AWB、64bin、冻结META、故障、背压、复位、短VS重叠。
3. 定向RAM回归：同/异bin、冻结流跨帧背压、RAM未知初值、连续APB INDEX/DATA、逐像素OSD。
4. 显示直方图、异步OSD、启动彩条、帧率诊断、shared DDR、固件回归。
5. 完整Efinity compile：RAM映射、无自动Debugger、仅RAW10、最终setup/hold；保留既有接口/未约束警告的说明。
6. 实际结果写入本节和reports/resource_optimization/README.md。没有开发板连接，不声明实板颜色、AE/AWB、MIPI信号完整性或显示效果已验证。

### 2026-10-12 实施结果

状态：P1/P2/P3已实施，离线仿真、配置审计及完整Efinity compile通过。P4/P5/P6未实施。

| 项目 | 本次修改前基线 | 优化后 | 变化 |
| --- | ---: | ---: | ---: |
| XLR / 60,800 | 55,159（90.72%） | 34,767（57.18%） | -20,392（减少36.97%） |
| 存储块 / 256 | 147（57.42%） | 153（59.77%） | +6 |
| DSP / 160 | 19 | 19 | 0 |
| 最小setup slack | 0.397 ns | 0.407 ns | 均为正 |
| 最小hold slack | 0.026 ns | 0.026 ns | 均为正 |

优化后剩余26,033 XLR、103存储块、141 DSP。XLR占用下降33.54个百分点；不是原先估算的17～19k或约55%。这些是P1/P2/P3合并后的实际结果，未进行逐阶段独立构建，不能据此拆分各项独立贡献。

- P1：网表确认hist_mem使用2个EFX_DPRAM10，previous_row/hist_cache/counts/heights/page_mem各使用1个EFX_RAM10。新映射增加7块，P2删除Debugger的1块，净增6块。冻结META、标量发布副本及ACTIVE镜像保留。
- P2：自动edb_top层次消失，CPU USER1/JTAG及DEBUG配置保留；旧视频探针配置保留。
- P3：保留depack40bit_inst；depack48/56/64bit_inst消失，CSI厂商源码及受保护块未修改。
- 仿真：双帧1920×1080精确AE/AWB/64bin、连续APB INDEX→DATA、跨三帧冻结背压、未知RAM初值与复位、52,800逐像素文字、完整显示直方图、异步OSD、启动/诊断、resize/DMA/CVO、共享DDR与真实RV32固件回归全部PASS。
- Efinity：基线map/debug/interface/PNR/PGM全部PASS；优化版map/interface/PNR/PGM全部PASS，自动debug阶段按P2关闭。最终采集域setup1.609ns、HDMI域7.632ns、CPU域3.452ns。

已有SDC/JTAG未匹配时钟警告，以及jtag_inst1部分输入与ddr_addr[15:14]缺失接口警告仍存在；正slack结论只覆盖当前SDC实际分析的路径。无开发板连接，完整厂商CSI协议、物理MIPI、实际显示/AE/AWB效果仍待上板验证。

详细日志、RAM网表证据、bit/配套未修改ELF和SHA256见[验证报告](../reports/resource_optimization/README.md)、[机器汇总](../reports/resource_optimization/validation.json)及[输入与产物哈希](../reports/resource_optimization/manifest.json)。
