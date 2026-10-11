"""Deterministic split with conservative dHash connected-component grouping."""
import argparse, hashlib, json, random
from pathlib import Path
import numpy as np
from PIL import Image


def main():
    p=argparse.ArgumentParser(); p.add_argument('--dataset',type=Path,required=True)
    p.add_argument('--out',type=Path,required=True); a=p.parse_args(); a.out.mkdir(parents=True,exist_ok=True)
    records=[]
    for domain in 'AB':
        rows=[]
        for split in ('train','test'):
            for path in sorted((a.dataset/(split+domain)).glob('*.jpg')):
                im=Image.open(path).convert('RGB'); small=np.asarray(im.resize((9,8))).mean(2)
                dh=sum(int(v)<<i for i,v in enumerate((small[:,1:]>small[:,:-1]).ravel()))
                rows.append(dict(path=path.relative_to(a.dataset).as_posix(),domain=domain,
                    original_split=split,sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                    rgb_sha256=hashlib.sha256(im.tobytes()).hexdigest(),dhash=f'{dh:016x}'))
        parent=list(range(len(rows)))
        def root(i):
            while parent[i]!=i: parent[i]=parent[parent[i]]; i=parent[i]
            return i
        # Hamming distance <=4: five buckets guarantee at least one unchanged bucket.
        buckets={}; near=[]
        for i,r in enumerate(rows):
            h=int(r['dhash'],16); candidates=set()
            for b in range(5): candidates.update(buckets.get((b,(h>>(13*b))&8191),[]))
            for j in candidates:
                dist=(h^int(rows[j]['dhash'],16)).bit_count()
                if dist<=4:
                    parent[root(i)]=root(j); near.append([r['path'],rows[j]['path'],dist])
            for b in range(5): buckets.setdefault((b,(h>>(13*b))&8191),[]).append(i)
        groups={}
        for i in range(len(rows)): groups.setdefault(root(i),[]).append(i)
        rng=random.Random(20261012); keys=sorted(groups); rng.shuffle(keys)
        val=set(keys[:max(1,len(keys)//10)])
        for key,ids in groups.items():
            test=any(rows[i]['original_split']=='test' for i in ids)
            for i in ids:
                rows[i]['split']='test' if test else 'validation' if key in val else 'train'
                rows[i]['group']=f'{domain}_{min(ids)}'
        records.extend(rows)
        (a.out/f'near_duplicates_{domain}.json').write_text(json.dumps(near,indent=2))
        print(domain,{s:sum(r['split']==s for r in rows) for s in ('train','validation','test')},flush=True)
    manifest={'dataset':str(a.dataset.resolve()),'seed':20261012,'method':'dHash <=4 connected components; original test groups reserved; no manual scene audit', 'records':records}
    (a.out/'manifest.json').write_text(json.dumps(manifest,indent=2))
    # Style exemplar choices are training-only and reproducibly spread over painting filenames.
    paintings=[r['path'] for r in records if r['domain']=='A' and r['split']=='train']
    styles=[paintings[i*(len(paintings)-1)//7] for i in range(8)]
    (a.out/'style_refs.json').write_text(json.dumps(styles,indent=2))
    sheet=Image.new('RGB',(8*192,216),'white')
    for i,name in enumerate(styles): sheet.paste(Image.open(a.dataset/name).convert('RGB').resize((192,192)),(i*192,24))
    sheet.save(a.out/'style_refs.png')

if __name__=='__main__': main()
