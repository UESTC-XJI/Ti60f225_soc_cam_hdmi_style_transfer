import json
import re
from datetime import datetime, timedelta
from pathlib import Path
from statistics import mean

root = Path(__file__).resolve().parent
records = [json.loads(line) for line in (root/'uart_timestamped.jsonl').read_text(encoding='utf-8').splitlines()]
def fields(line):
    return {key: int(value) for key, value in re.findall(r'(\w+) (\d+)', line)}
def select(prefix, start=None, end=None):
    result=[]
    for record in records:
        when=datetime.fromisoformat(record['time'])
        if record['line'].startswith(prefix) and (start is None or when>=start) and (end is None or when<end):
            result.append((record,fields(record['line'])))
    return result
def stats(rows):
    if not rows:
        return {}
    keys=rows[0][1].keys()
    return {k:{'min':min(v[k] for _,v in rows), 'max':max(v[k] for _,v in rows), 'mean':round(mean(v[k] for _,v in rows),3)} for k in keys}
def summarize(start=None,end=None):
    video=select('VIDEO ',start,end)
    monet=select('MONET ',start,end)
    ddr=select('DDR100M ',start,end)
    result={'video_samples':len(video),'video':stats(video),'monet':stats(monet),'ddr':stats(ddr)}
    if len(video)>1:
        elapsed=video[-1][0]['seconds']-video[0][0]['seconds']
        delta=(video[-1][1]['UF']-video[0][1]['UF'])&0xffffffff
        result.update(start=video[0][0]['time'],end=video[-1][0]['time'],elapsed_s=round(elapsed,3),underflow_increment=delta,underflow_events_per_s=round(delta/elapsed,3))
    if len(ddr)>1:
        valid=ddr[1:]
        ticks=sum(v['T'] for _,v in valid)
        result['display_read_MBps']=round(sum(v['DRB'] for _,v in valid)*16/(ticks/1e8)/1e6,3) if ticks else None
        result['cnn_read_MBps']=round(sum(v['RB'] for _,v in valid)*16/(ticks/1e8)/1e6,3) if ticks else None
    return result
disable_path=root/'disable_time.txt'
restore_path=root/'restore_time.txt'
disable=datetime.fromisoformat(disable_path.read_text(encoding='utf-8-sig').strip()) if disable_path.exists() else None
restore=datetime.fromisoformat(restore_path.read_text(encoding='utf-8-sig').strip()) if restore_path.exists() else None
halt_path=root/'cpu_halt_time.txt'
halt=datetime.fromisoformat(halt_path.read_text(encoding='utf-8-sig').strip()) if halt_path.exists() else None
first_video=select('VIDEO ')[0][0]
settled=datetime.fromisoformat(first_video['time'])+timedelta(seconds=3)
result={'baseline':summarize(settled,disable)}
if disable:
    result['display_only']=summarize(disable+timedelta(seconds=2),restore)
if restore:
    result['restored']=summarize(restore+timedelta(seconds=2),halt)
(root/'uart_summary.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print(json.dumps(result,ensure_ascii=False,indent=2))
