"""Package the routed QSE UI candidate and its reproducibility evidence."""
from pathlib import Path
import hashlib, json, shutil, os, re, subprocess
R=Path(__file__).resolve().parents[1]
F=R/'outflow_qse_ui_final'
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
bit=F/'ti60f225_oob.bit'
version='qse-ui_'+sha(bit)[:12]
O=R/'reports/versions'/version
O.mkdir(parents=True,exist_ok=True)
items=[(bit,'artifacts/ti60f225_oob.bit'),(R/'software/firmware/build/soc_video_app.elf','artifacts/soc_video_app.elf'),(R/'software/firmware/build/soc_video_app.bin','artifacts/soc_video_app.bin'),(R/'QSE_UI.md','QSE_UI.md')]
for suffix in ['place.rpt','route.rpt','timing.rpt','hier_util.rpt','pinout.csv','pgm.out','cdc.rpt']:
    p=F/('ti60f225_oob.'+suffix)
    if p.exists(): items.append((p,'evidence/'+p.name))
for name in ['qse_ui_verified_tests.log','qse_ui_final_compile.log','qse_ui_final_pgm.log']:
    p=Path(os.environ['TMPDIR'])/name
    items.append((p,'evidence/'+name))
sources=['rtl/ti60f225_oob_top.v','rtl/soc_integration/qse_gpio_sync.sv','rtl/soc_integration/qse_ui_control.sv','rtl/soc_integration/osd_text_double_buffer.sv','rtl/soc_integration/soc_video_ddr_integration.sv','rtl/style/style_display.sv','rtl/style/style_video_system.sv','soc/efx_sapphire_soc/soc/soc.v','soc/efx_sapphire_soc/soc/settings.json','ti60f225_cam_hdmi.xml','ti60f225_oob.peri.xml','ti60f225_oob.sdc','tools/test_qse.py']
sources += [str(p.relative_to(R)) for p in (R/'tests').glob('qse*tb.sv')]
items += [(R/p,'inputs/'+p) for p in sources]
for src,rel in items:
    dst=O/rel;dst.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(src,dst)
report='''# QSE UI candidate — offline verified, not board tested

- Branch: qse-extension. No commit or board programming performed.
- Rotary label only: 0:origin / 1:style1 / 2:style2 / 3:style3. No model/weight changes.
- KEY0 toggles OSD/histogram, default on. KEY1 toggles side-by-side comparison / centered single styled VGA image, default comparison.
- RTL 20 ms contact debounce, press edge, no autorepeat. Whole-selector candidate stability. Frame-boundary publishing; row mode crosses via request FIFO.
- Existing metrics moved to y=40, label at (16,16). Existing firmware rebuilt without business-logic changes.

## Verification

QSE suite passed: GPIO/pins/UART regression; key bounce/hold/repress; all Gray states; exact four labels; 19,200 label pixels; 3 full display frames with 1,536,000 checked image pixels and no simulated underflow/DMA errors. Font equivalence passed. Existing OSD regression independently passed 52,800 exact pixels.

Efinity map/interface/pnr/pgm passed. Final constrained clock-relationship worst setup +0.281 ns, hold +0.026 ns. XLR 56,338/60,800; RAM 239/256; DSP 140/160. Prior QSE-only routed placement: XLR 56,047; RAM 239; DSP 140. UI net increase: 291 XLR, no additional RAM/DSP.

The discarded first UI attempt prevented character RAM inference and reached 59,049 XLR. Final code restores unconditional registered dual-clock RAM read before the label mux.

## Remaining gates / inherited warnings

Not programmed or board-verified. Confirm selector physical detent ordering and key polarity on hardware. Board display stability, real switching and actual contact bounce remain unmeasured. Existing JTAG clock/constraint warnings and missing unused interface ports remain; positive constrained timing is not proof all external interfaces are constrained. Tool logs also contain the inherited 'cannot find correct IV value' warning. Icarus emits existing font always_comb sensitivity and testbench force limitations; exact pixel scoreboards pass.

Use only the artifacts in this directory as this candidate; outflow_qse_ui contains an abandoned attempt. Full behavior and reproduction commands: QSE_UI.md.
'''
(O/'REPORT.md').write_text(report)
manifest={'version':version,'bit_sha256':sha(bit),'board_verified':False,'source_branch':subprocess.check_output(['git','branch','--show-current'],cwd=R,text=True).strip(),'files':{str(p.relative_to(O)):sha(p) for p in sorted(O.rglob('*')) if p.is_file() and p.name!='manifest.json'}}
(O/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
for rel,digest in manifest['files'].items(): assert sha(O/rel)==digest,rel
print(O)
print('Verified manifest:',len(manifest['files']),'files')
print('Bit SHA256:',sha(bit))
