#!/usr/bin/env python3
"""Run independent Release processes on new external fixtures; never retry failures."""
import argparse,hashlib,json,platform,statistics,subprocess,time
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--executable',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--sizes',default='1000,10000');p.add_argument('--repetitions',type=int,default=3);a=p.parse_args()
repo=Path(__file__).resolve().parents[2];out=a.output.resolve();sizes=[int(x) for x in a.sizes.split(',')]
if out.exists() or out==repo or repo in out.parents or not sizes or any(x<10 or x>50000 for x in sizes) or a.repetitions<1:p.error('New external output, sizes 10...50000 and positive repetitions required.')
out.mkdir();exe=a.executable.resolve();ops=['equality','range','count','compound','sort','prefix','date','unsigned','count-direct','compound-staged'];samples=[]
def call(variant,op,n,root,rep):
 tag=f'{n}-{rep}-{variant}-{op}';start=time.monotonic()
 r=subprocess.run([str(exe),variant,op,str(n),str(root)],text=True,capture_output=True)
 (out/(tag+'.stdout')).write_text(r.stdout);(out/(tag+'.stderr')).write_text(r.stderr)
 if r.returncode:raise SystemExit(f'FAILED {tag}; retained logs, no retry.')
 lines=r.stdout.strip().splitlines();data=json.loads(lines[-1]);data['repetition']=rep;data['wallSeconds']=time.monotonic()-start;data['semanticNotes']=lines[:-1];samples.append(data)
 with (out/'samples.jsonl').open('a') as f:f.write(json.dumps(data,sort_keys=True)+'\n')
 print(tag+': '+str(round(data['seconds']*1000,3))+' ms',flush=True)
host=next((parent for parent in exe.parents if (parent/'laboratory-pin.json').exists()),None)
if host is None:raise SystemExit('Missing exported laboratory pin.')
pin=json.loads((host/'laboratory-pin.json').read_text())
if pin['overlaySHA256']!=hashlib.sha256((host/'TypedPropertyLab/Probe.swift').read_bytes()).hexdigest():raise SystemExit('Laboratory overlay hash mismatch.')
env={'laboratoryPin':pin,'binarySHA256':hashlib.sha256(exe.read_bytes()).hexdigest(),'platform':platform.platform(),'executable':str(exe),'sizes':sizes,'repetitions':a.repetitions,'startedUTC':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),'gitHead':subprocess.check_output(['git','-C',str(repo),'rev-parse','HEAD'],text=True).strip(),'dirty':bool(subprocess.check_output(['git','-C',str(repo),'status','--porcelain'],text=True))}
(out/'environment.json').write_text(json.dumps(env,indent=2)+'\n')
for n in sizes:
 for rep in range(a.repetitions):
  # Rotate variant order. Each trial gets a new seed; query processes reopen it independently.
  order=['envelope','typed','indexed'];order=order[rep%3:]+order[:rep%3]
  for variant in order:
   root=out/f'fixture-{n}-{rep}-{variant}'
   call(variant,'seed',n,root,rep);call(variant,'audit',n,root,rep)
   for op in ops:call(variant,op,n,root,rep)
   call(variant,'mutate',n,root,rep);call(variant,'verify-mutated',n,root,rep)
lines=['# Typed properties laboratory summary','','Operation medians; fresh processes, uncontrolled OS/file caches. Not full Graph query latency.','', '| Nodes | Operation | Envelope ms | Typed ms | Indexed ms |','|---:|---|---:|---:|---:|']
for n in sizes:
 for op in ['seed']+ops+['mutate']:
  vals=[statistics.median(s['seconds']*1000 for s in samples if s['nodes']==n and s['operation']==op and s['variant']==v) for v in ['envelope','typed','indexed']]
  lines.append(f'| {n} | {op} | '+' | '.join(f'{x:.3f}' for x in vals)+' |')
lines+=['','| Nodes | Variant | Closed seed bytes | Process peak RSS MiB (query maximum) |','|---:|---|---:|---:|']
for n in sizes:
 for v in ['envelope','typed','indexed']:
  seed=statistics.median(s['directoryBytes'] for s in samples if s['nodes']==n and s['operation']=='seed' and s['variant']==v)
  rss=max(s['processPeakRSSBytes'] for s in samples if s['nodes']==n and s['operation'] in ops and s['variant']==v)/1048576
  lines.append(f'| {n} | {v} | {seed:.0f} | {rss:.1f} |')
(out/'summary.md').write_text('\n'.join(lines)+'\n')
