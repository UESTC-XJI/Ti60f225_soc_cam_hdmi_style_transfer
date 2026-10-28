from pathlib import Path
import hashlib,json,re,shutil,datetime,difflib
R=Path(__file__).resolve().parents[1]
def h(p):return hashlib.sha256(p.read_bytes()).hexdigest()
m=json.loads((R/'reports/baseline/source_manifest.json').read_text());S=Path(m['source'])
assert all(h(S/n)==v for n,v in m['files'].items()),'Original source changed'
bit=R/'outflow_widths/ti60f225_oob.bit'
version=datetime.datetime.now().strftime('%Y-%m-%d')+'_osd-stats_'+h(bit)[:12]
D=R/'reports/versions'/version;D.mkdir(parents=True,exist_ok=True)
text='''OSD字库与采集统计资源优化报告

状态：独立候选，已生成bit和配套ELF，未上板、未烧录。不推断FPS或物理链路等价。
基线：原Ti60f225_soc_cam_hdmi_style_demo完整源快照；未采用lite或prefetch兄弟候选。
本机同Efinity2026.1.132、Ti60F225 I3、TIMING_3 seed0，基线与组合候选均map/interface/pnr/pgm PASS。

资源比较（最终布局）
                  基线        仅字库试验       字库+统计位宽
XLR               57870       58837            57278
RAM               256         254              254
DSP               140         140              140
仅字库试验布线较慢，主动停止，只有布局结果，未作为成功发布。其整工程XLR增加不能忽略。
组合候选净减少592 XLR、2块RAM；DSP不变。RAM余2/256，逻辑仍接近容量。
统计器层次3269.5→2741.5 XLR；scalar_mailbox655→439 XLR是常量零位传播后的综合收益，不是删除或合并mailbox。
font4→2 RAM，osd_db5→3 RAM；统计器3 RAM和5 DSP不变。

时序
组合候选CNN148.5MHz setup+0.286ns；core100MHz+2.249ns；HDMI74.25MHz+6.811ns。
所有已报告setup关系为正，最小setup+0.138ns，hold+0.026ns。CDC无Synchronizer警告。
原有JTAG/DDR接口约束警告仍在，不宣称所有板级路径约束完整。

实现
1. 字库改128字符×16行×8位，保留全部95个可打印ASCII(大小写/数字/标点)，不做字符集功能收缩。
   非打印/高位字符映射空格；仿真未知字符也明确为空白。单拍同步ROM读不变。
   未修改双页字符RAM、COMMIT/ACK、活动页保护或三拍RGB/DE/HS/VS。
2. 按参数导出最大采样数并缩小内部实时/完成帧累加器；对外384位统计包每个字段仍32位且零扩展。
   1080p：AE32400需15位；AWB16200需14位。
   R/B最大255×16200=4131000需22位；G=510×16200=8262000需23位；Y=255×32400=8262000需23位。
   增益保留完整16位：校正最大510×65535=33422850需25位；比例积最大2190366474750需41位。
   原AWB四拍有效/颜色/筛选流水不变，没有减级。帧号、配置版本、APB接口保留。
3. 保留实时、完成帧、发布包和冻结META：其生命周期能重叠，不能安全直接合并。

乘法器复用评估（未实施）
稀疏AWB同一行采样通常间隔8拍，现有三个增益乘法和比例乘法并行流水。单增益乘法器复用至少要串行处理R/G/B，延迟结果比较和候选提交，并携带有效、RAW值、帧/配置边界标签。
仅有8拍间隔不证明跨行/短VS/帧尾都安全；改变采样提交延迟还会影响raw_end完成帧快照。当前未新增带标签调度与末尾flush证明，故不冒险将复用加入本交付，DSP收益为0。下一步须独立候选和差分回归。

已执行验证
- RED：旧ROM未知字符测试失败；改后全部256字符×16行×8像素位与不可变基线字形一致，未知字符空白。
- 52800个OSD输出像素对拍、双页80字符、颜色/位置、三拍同步一致。
- 双页异步COMMIT/ACK、活动页保护、帧边界开关；缺失en2反例仍能复现预期失败。
- RED：旧统计内部位宽预算断言失败；改后通过。
- 统计小尺寸差分与完整1920×1080差分：7359692周期逐拍比较累加器、标量发布、冻结直方图，7次统计握手和322词直方图握手。
- 完整1080p真实gain/Debayer/统一APB两帧，AE32400/AWB16200、全部64bin和CFG提交对拍。
- 小尺寸真实Debayer/APB覆盖零候选、坏帧、短VS重叠、配置切换、CDC背压、序号回绕、冻结期间新帧继续。
- BRAM同/异bin、冻结跨三帧、稳定背压流、bank复用和复位通过。
- 真实RISC-V工具链重建ELF：text44620/data4/bss688。
- 实际RV32 ELF启动/故障回归和17项AE/AWB/冻结直方图软件模型测试通过；模型不是Sapphire RTL/缓存/物理I2C测试。
- 原工程基线清单691项文件重新SHA256核验不变，CNN与权重未改。

限制与审查
仅实施字库压缩与统计位宽；不宣称完成乘法共享和生命周期存储合并。
未进行新候选实板MIPI/DDR/HDMI、画质或持续并发FPS测量；仍需用此bit+ELF上板验收。
Git旧worktree元数据未复制/修复；使用不可变源清单和逐文件差分自审。无独立审查agent接口，本次为自审+工具验证，不宣称独立审查通过。
运行现有Icarus脚本时通过可见的portable runner替换Windows可执行文件路径；旧工具脚本保留，未改RTL测试的验收断言。
font生成器同步更新ROM结构；历史字体路径仍依赖CascadiaMono.ttf，本轮直接保留原位图，未重新生成字体。
本机工具位于Hermes scratch，环境可能被清理；长期复现需安装Icarus12、Python3.12 numpy/unicorn/pyelftools及既有Efinity/RISC-V工具链。
'''
(D/'REPORT.txt').write_text(text)
items=[(bit,'artifacts/ti60f225_oob.bit'),(R/'software/firmware/build/soc_video_app.elf','artifacts/soc_video_app.elf'),(R/'software/firmware/build/soc_video_app.bin','artifacts/soc_video_app.bin')]
for n in ['place.rpt','hier_util.rpt','timing.rpt','route.rpt','cdc.rpt','pgm.out']:
 items.append((R/'outflow_widths'/('ti60f225_oob.'+n),'evidence/'+n))
for p in (R/'reports/validation').glob('*.log'):items.append((p,'validation/'+p.name))
for n in ['ti60f225_cam_hdmi.xml','ti60f225_oob.sdc','rtl/soc_integration/osd_font8x16.sv','rtl/isp/capture_frame_stats.sv','tools/gen_font.py','tools/test_capture_widths.py','tools/test_compact_font.py','tests/capture_equivalence_tb.sv','tools/run_portable_regression.py']:
 items.append((R/n,'inputs/'+n))
for p in (R/'outflow_control').glob('*.rpt'):
 if p.name.endswith(('place.rpt','timing.rpt','hier_util.rpt')):items.append((p,'baseline/'+p.name))
items.append((R/'reports/baseline/source_manifest.json','baseline/source_manifest.json'))
for src,target in items:
 dst=D/target;dst.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(src,dst);assert h(src)==h(dst)
files={str(p.relative_to(D)):{'bytes':p.stat().st_size,'sha256':h(p)} for p in D.rglob('*') if p.is_file()}
(D/'manifest.json').write_text(json.dumps({'version':version,'source':str(S),'board_verified':False,'resources':{'baseline':{'xlr':57870,'ram':256,'dsp':140},'candidate':{'xlr':57278,'ram':254,'dsp':140}},'files':files},indent=2))
(R/'reports/README.md').write_text(f'# 资源优化候选报告\n\n当前版本：[完整报告](versions/{version}/REPORT.txt)。\n\n基线、字库、组合候选分开比较；组合候选已完整编译和回归，未上板。\n')
latest=R/'reports/latest'
if latest.is_symlink():latest.unlink()
latest.symlink_to(Path('versions')/version,target_is_directory=True)
for n,v in files.items():assert h(D/n)==v['sha256']
assert latest.resolve()==D.resolve()
print(json.dumps({'version':version,'report':str(D/'REPORT.txt'),'verified_files':len(files),'original_baseline_files_unchanged':len(m['files']),'bit_sha256':h(bit)},indent=2))
