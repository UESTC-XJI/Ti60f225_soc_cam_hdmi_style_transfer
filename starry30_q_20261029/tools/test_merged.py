from pathlib import Path
import subprocess,os,json,time,hashlib
r=Path(__file__).resolve().parents[1];rep=r/'reports/versions/merged-lite-osd-stats-prefetch';env=os.environ.copy()
env.update(IVERILOG='/home/goodmann/.hermes/cache/scratch/ti60_sim_bin/iverilog',VVP='/home/goodmann/.hermes/cache/scratch/ti60_sim_bin/vvp',SOC_RISCV_TOOLCHAIN='/home/goodmann/efinity/efinity-riscv-ide-2026.1/toolchain/bin')
py='/home/goodmann/.hermes/cache/scratch/ti60_status/simenv/bin/python'
(r/'reports/simulation').mkdir(parents=True,exist_ok=True)
cases=[['tools/test_compact_font.py'],['tools/test_capture_widths.py','--full'],['tools/run_native.py','tools/test_soc_cleanup.py'],['tools/run_native.py','tools/test_video_3a.py'],['tools/test_style_prefetch.py','--require-overlap'],['tools/test_style_prefetch.py','--fault','prefetch_read'],['tools/test_style_prefetch.py','--fault','prefetch_write'],['tools/test_style_prefetch.py','--fault','reset'],['tools/run_native.py','tools/test_style_accel.py'],['tools/run_native.py','tools/test_style_display_deadline.py'],['tools/run_native.py','tools/test_style_shared.py'],['tools/build_firmware.py'],['tools/test_firmware_runtime.py'],['tools/test_camera_3a_runtime.py']]
results=[]
for i,args in enumerate(cases):
 print('RUN',args,flush=True);t=time.monotonic();p=subprocess.run([py,*args],cwd=r,env=env,capture_output=True,text=True,timeout=1200)
 (rep/f'test_{i:02d}.log').write_text(p.stdout+p.stderr)
 results.append({'command':args,'returncode':p.returncode,'seconds':time.monotonic()-t,'log':f'test_{i:02d}.log'})
 (rep/'regression.json').write_text(json.dumps(results,indent=2)+'\n');print(p.stdout[-2500:],flush=True)
 if p.returncode:print(p.stderr[-2500:],flush=True);raise SystemExit(p.returncode)
print('PASS all merged directed regressions',flush=True)
