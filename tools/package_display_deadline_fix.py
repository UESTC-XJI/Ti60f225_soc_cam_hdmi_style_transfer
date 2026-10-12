"""Save the verified display deadline bit and paired diagnostic firmware."""
from pathlib import Path
import hashlib
import json
import re
import shutil

ROOT=Path(__file__).resolve().parents[1]
FLOW=ROOT/'outflow_style_deadline_reserve'
REPORT=ROOT/'reports/style_demo/display_deadline'
RELEASE=ROOT/'reports/style_demo/release_display_deadline'
def digest(path):
    data=path.read_bytes()
    return {'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()}
def main():
    log=(REPORT/'build_reserve.log').read_text(errors='replace')
    for phase in ('map','interface','pnr','pgm'):
        assert re.search(rf'\b{phase}\s*:\s*PASS',log),phase
    timing=(FLOW/'ti60f225_oob.timing.rpt').read_text()
    section=timing.split('Setup (Max) Clock Relationship')[1].split('NOTE: Values')[0]
    setup,hold=section.split('Hold (Min) Clock Relationship')
    pattern=r'^\s*(\S+)\s+(\S+)\s+(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+\([RF]-[RF]\)'
    srows=re.findall(pattern,setup,re.M);hrows=re.findall(pattern,hold,re.M)
    assert srows and hrows and all(float(row[3])>=0 for row in srows+hrows),'timing'
    cdc=(FLOW/'ti60f225_oob.cdc.rpt').read_text()
    assert 'No Synchronizer warnings' in cdc,'CDC report needs review'
    resource=(FLOW/'ti60f225_oob.place.rpt').read_text()
    resources={}
    for key,label in [('XLR','XLRs'),('RAM','Memory Blocks'),('DSP','DSP Blocks')]:
        m=re.search(rf'^{label}: (\d+) / (\d+)',resource,re.M)
        assert m,label
        used,capacity=map(int,m.groups());assert used<=capacity
        resources[key]={'used':used,'capacity':capacity}
    simulation=json.loads((ROOT/'reports/style_demo/ddr_optimization/adaptive_reserve/metrics.json').read_text())
    for name,sha in simulation['rtl_sha256'].items():
        assert digest(ROOT/name)['sha256']==sha,'RTL changed after simulation: '+name
    assert simulation['underflows']==0 and simulation['capture_beats']==76800
    contention=json.loads((REPORT/'contention/metrics.json').read_text())
    assert contention['0']['underflow']>0 and contention['2']['underflow']==0
    assert 'PASS' in (REPORT/'units/simulation.log').read_text()
    RELEASE.mkdir(parents=True,exist_ok=True)
    shutil.copy2(FLOW/'ti60f225_oob.bit',RELEASE/'ti60f225_oob.bit')
    shutil.copy2(ROOT/'reports/style_demo/flicker_diagnostics/soc_video_app.elf',RELEASE/'soc_video_app.elf')
    sources=[ROOT/name for name in simulation['rtl_sha256']]
    sources += [ROOT/'ti60f225_cam_hdmi.xml',ROOT/'ti60f225_oob.sdc',ROOT/'docs/DISPLAY_DEADLINE_FIX.md']
    for suffix in ('timing.rpt','place.rpt','cdc.rpt','route.rpt','pgm.out'):
        sources.append(FLOW/f'ti60f225_oob.{suffix}')
    sources += [RELEASE/'ti60f225_oob.bit',RELEASE/'soc_video_app.elf']
    manifest={'resources':resources,'setup_slack_ns':{f'{a}->{b}':float(slack) for a,b,_,slack in srows},'minimum_hold_slack_ns':min(float(row[3]) for row in hrows),'simulation':simulation,'contention':contention,'hardware_programmed':False,'files':{p.relative_to(ROOT).as_posix():digest(p) for p in sources}}
    (RELEASE/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    (RELEASE/'README.md').write_text('# 显示紧急读通道保留版\n\n使用本目录 bit 与诊断 ELF 配套下载。显示急需数据时禁止在拆包间隙插入新的 CNN 读突发；非紧急时恢复公平仲裁。网络/权重不变。\n\n编译、时序和 RTL 回归均通过，数值见 manifest.json。实板结果见 hardware/README.md（如已生成）。\n\nJTAG 配置 FPGA 后等待 DDR 校准，CPU reset halt → load ELF → 设置 _start → 显式 resume。不包含 Flash 自启动镜像。\n',encoding='utf-8')
    print(json.dumps({'resources':resources,'cnn_slack':manifest['setup_slack_ns']['vid_clk_dvi2->vid_clk_dvi2'],'core_slack':manifest['setup_slack_ns']['core_clk->core_clk'],'hold':manifest['minimum_hold_slack_ns'],'bit':digest(RELEASE/'ti60f225_oob.bit')},indent=2))
if __name__=='__main__':
    main()
