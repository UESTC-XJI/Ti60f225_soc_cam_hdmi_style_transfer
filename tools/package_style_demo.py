"""Package verified deployment artifacts and content hashes; never program hardware."""
from pathlib import Path
import hashlib,json,re,shutil,subprocess,xml.etree.ElementTree as ET
ROOT=Path(__file__).resolve().parents[1]
REPORT=ROOT/'reports/style_demo'
RESULTS=ROOT/'docs/style_demo_results'
RELEASE=REPORT/'release'

def digest(path):
    raw=path.read_bytes()
    return {'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest()}

def copy(source,destination):
    destination.parent.mkdir(parents=True,exist_ok=True)
    shutil.copy2(source,destination)

def main():
    # Require successful, matching full-frame and actual integrated RTL runs.
    assert '640x480 full graph exact RGB' in (REPORT/'vga_480/simulation.log').read_text()
    assert 'PASS' in (REPORT/'system/simulation.log').read_text()
    for name in ['vga_demo.png','heldout_comparison.png','metrics.json']:
        copy(REPORT/'evaluation'/name,RESULTS/name)
    if (REPORT/'baseline_snapshot.json').exists():
        copy(REPORT/'baseline_snapshot.json',RESULTS/'baseline_snapshot.json')
    for stage in ['teacher_v2','student','qat_recovery']:
        for p in (REPORT/stage).iterdir():
            if p.name=='train.jsonl' or p.name=='config.json' or p.name.startswith('validation_') and p.suffix=='.json':
                copy(p,RESULTS/'training'/stage/p.name)
    for stage in ['mac','rows','network','accel','errors','shared','video','vga_48','vga_480','system']:
        for p in (REPORT/stage).iterdir():
            if p.suffix=='.log' or p.name=='metrics.json':
                copy(p,RESULTS/'simulation'/stage/p.name)
    for phase in ['map','interface','pnr','pgm']:
        copy(REPORT/f'efinity_{phase}_final.log',RESULTS/'efinity'/f'{phase}.log')
    for suffix in ['timing.rpt','hier_util.rpt','cdc.rpt','route.rpt','res.csv','pgm.out']:
        copy(ROOT/'outflow_style_final'/f'ti60f225_oob.{suffix}',RESULTS/'efinity'/f'ti60f225_oob.{suffix}')
    copy(ROOT/'outflow_style_final/ti60f225_oob.bit',RELEASE/'ti60f225_oob.bit')
    copy(ROOT/'software/firmware/build/soc_video_app.elf',RELEASE/'soc_video_app.elf')
    copy(ROOT/'ti60f225_cam_hdmi.xml',RELEASE/'build_project.xml')
    model=json.loads((ROOT/'ml/style_transfer/artifacts/manifest.json').read_text())
    for name,info in model['files'].items():
        assert digest(ROOT/'ml/style_transfer/artifacts'/name)==info,name
    data=json.loads((REPORT/'data_v2/manifest.json').read_text())
    evaluation=json.loads((RESULTS/'metrics.json').read_text())
    assert evaluation['manifest_sha256']==digest(REPORT/'data_v2/manifest.json')['sha256']
    assert evaluation['qat_checkpoint_sha256']==model['files']['student_qat.pt']['sha256']
    splits={r['path']:r['split'] for r in data['records']}
    assert evaluation['count']==len(evaluation['items'])==64
    assert all(splits[r['path']]=='test' for r in evaluation['items'])
    qat_config=json.loads((REPORT/'qat_recovery/config.json').read_text())
    assert all(splits[name]=='train' for name in qat_config['style_refs'])
    assert (ROOT/'rtl/style/model/coeff.hex').read_bytes()==(ROOT/'ml/style_transfer/artifacts/integer/coeff.hex').read_bytes()
    # Preserve exact vendor protected bytes, independently of expanded-token checks.
    pattern=rb'`pragma protect begin_protected[\s\S]*?`pragma protect end_protected'
    baseline=subprocess.check_output(['git','show','85439b8:rtl/ti60f225_oob_top.v'],cwd=ROOT)
    original=re.findall(pattern,baseline)
    current=re.findall(pattern,(ROOT/'rtl/ti60f225_oob_top.v').read_bytes())
    # Git converts line endings; compare the original checkout bytes when present.
    snapshot=json.loads((RESULTS/'baseline_snapshot.json').read_text()) if (RESULTS/'baseline_snapshot.json').exists() else None
    untouched=None
    if snapshot and Path(snapshot['source']).exists():
        source=Path(snapshot['source'])
        assert re.findall(pattern,(source/'rtl/ti60f225_oob_top.v').read_bytes())==current
        for name,sha in snapshot['overlay_sha256'].items():
            assert digest(source/name)['sha256']==sha,'original workspace changed: '+name
        untouched=True
    else:
        assert [p.replace(b'\r\n',b'\n') for p in original]==[p.replace(b'\r\n',b'\n') for p in current]
    project=ET.parse(ROOT/'ti60f225_cam_hdmi.xml')
    sources={ROOT/p.attrib['name'] for p in project.iter() if p.tag.endswith('design_file')}
    protected_files={}
    for p in sorted(sources):
        blocks=re.findall(pattern,p.read_bytes())
        if not blocks:continue
        name=p.relative_to(ROOT).as_posix()
        if untouched:
            assert blocks==re.findall(pattern,(source/name).read_bytes()),name
        else:
            old=subprocess.check_output(['git','show','85439b8:'+name],cwd=ROOT)
            assert [b.replace(b'\r\n',b'\n') for b in blocks]==[b.replace(b'\r\n',b'\n') for b in re.findall(pattern,old)],name
        protected_files[name]=len(blocks)
    assert protected_files,'missing protected vendor sources'
    for folder in ['rtl/style','software/firmware','ml/style_transfer','tools','tests']:
        sources.update(p for p in (ROOT/folder).rglob('*') if p.is_file() and 'build' not in p.parts and '__pycache__' not in p.parts and p.suffix in ['.py','.sv','.v','.vh','.c','.h','.S','.ld','.hex','.json','.npz','.bin','.pt'])
    sources.update(p for p in ROOT.iterdir() if p.suffix in ['.xml','.sdc'])
    sources.update(ROOT/name for name in ['.gitattributes','.gitignore','MonetStyleDemo.code-workspace','docs/STYLE_TRANSFER_FPGA_PLAN.md','docs/STYLE_DEMO_IMPLEMENTATION.md','ml/style_transfer/README.md'])
    files={p.relative_to(ROOT).as_posix():digest(p) for p in sorted(sources)}
    for folder in [RESULTS,RELEASE]:
        files.update({p.relative_to(ROOT).as_posix():digest(p) for p in sorted(folder.rglob('*')) if p.is_file() and p.name!='manifest.json'})
    for p in (REPORT/'data_v2').glob('*.json'):
        files[p.relative_to(ROOT).as_posix()]=digest(p)
    manifest={
        'branch':subprocess.check_output(['git','branch','--show-current'],cwd=ROOT,text=True).strip(),
        'baseline_commit':'85439b8','efinity':'2026.1.132','device':'Ti60F225 I3',
        'model':model,'test_evaluation':evaluation,
        'full_vga':json.loads((REPORT/'vga_480/metrics.json').read_text()),
        'integrated_stress':json.loads((REPORT/'system/metrics.json').read_text()),
        'resources':{'XLR':59478,'XLR_capacity':60800,'RAM':254,'RAM_capacity':256,'DSP':140,'DSP_capacity':160,'LUT4':37837,'FF':28282},
        'timing_ns':{'cnn_setup':0.362,'core_setup':1.970,'min_reported_hold':0.026},
        'vendor_protected_files':protected_files,'vendor_protected_block_count':sum(protected_files.values()),'original_overlay_unchanged':untouched,
        'validation_scope':'Actual neural/video/AXI RTL against integer oracle and randomized behavioral DDR. Firmware uses actual RV32 ELF in Unicorn with modeled peripherals. Efinity top-level map/interface/pnr/pgm passed. No programming, board, physical-link, real video-quality or measured board-FPS validation.',
        'files':files}
    (RELEASE/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(f'PASS deployment package: {len(files)} hashed files, {sum(protected_files.values())} protected blocks; original overlay unchanged={untouched}')

if __name__=='__main__':main()
