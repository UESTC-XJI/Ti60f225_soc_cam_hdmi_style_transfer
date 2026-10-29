"""Preserve exact Git baseline plus its otherwise untracked debug inputs/bit."""
from pathlib import Path
import hashlib, json, shutil, subprocess, tarfile
ROOT=Path(__file__).resolve().parents[1]
SOURCE=ROOT.parent/'Ti60f225_soc_cam_hdmi_720p'
SHA='3ab82f8319c8f12284078f6373327093e50bb40e'
DEST=ROOT/'reports'/'baseline'
DEST.mkdir(parents=True,exist_ok=True)
archive=DEST/'sources.tar'
subprocess.run(['git','archive','--format=tar',f'--output={archive}',SHA],cwd=ROOT,check=True)
checkout=DEST/'checkout'
checkout.mkdir(exist_ok=True)
with tarfile.open(archive) as f: f.extractall(checkout,filter='data')
for relative in ['work_dbg/debug_top.v','work_dbg/debug_top.stub.v']:
    target=checkout/relative; target.parent.mkdir(parents=True,exist_ok=True)
    shutil.copy2(SOURCE/relative,target)
for relative in ['outflow/ti60f225_oob.bit','outflow/ti60f225_oob.timing.rpt','outflow/ti60f225_oob.place.rpt']:
    src=SOURCE/relative
    if src.exists():
        target=DEST/'original-artifacts'/Path(relative).name
        target.parent.mkdir(exist_ok=True); shutil.copy2(src,target)
manifest=[]
for folder in [checkout,DEST/'original-artifacts']:
    for path in sorted(folder.rglob('*')):
        if path.is_file(): manifest.append({'file':path.relative_to(DEST).as_posix(),'bytes':path.stat().st_size,'sha256':hashlib.sha256(path.read_bytes()).hexdigest()})
(DEST/'manifest.json').write_text(json.dumps({'commit':SHA,'files':manifest},indent=2),encoding='utf-8')
print(f'Preserved {len(manifest)} inputs/artifacts at {DEST}')
