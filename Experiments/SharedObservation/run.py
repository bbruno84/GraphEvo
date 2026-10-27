#!/usr/bin/env python3
"""Fresh isolated fixtures; copy each closed seed once per timed process. No retry."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import shutil
import statistics
import subprocess

CASES = {"small":(100,0),"flat-500":(500,0),"flat-2000":(2000,0),"file-1":(100,1),"file-10":(100,10)}
p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--output", type=Path, required=True)
p.add_argument("--executable", type=Path, required=True)
p.add_argument("--cases", default=",".join(CASES))
p.add_argument("--counts", default="1,8,32")
p.add_argument("--modes", default="equal,mixed")
p.add_argument("--repetitions",type=int,default=5)
a=p.parse_args(); root=a.output.resolve(); binary=a.executable.resolve(); repo=Path(__file__).resolve().parents[2]
cases=a.cases.split(","); counts=list(map(int,a.counts.split(","))); modes=a.modes.split(",")
if root.exists() or root == repo or repo in root.parents or not binary.is_file() or set(cases)-CASES.keys() or set(counts)-{1,8,32} or set(modes)-{"equal","mixed"} or a.repetitions<1: p.error("Use a fresh external directory, built binary and supported matrix")
root.mkdir(parents=True)
(root/"environment.json").write_text(json.dumps(dict(platform=platform.platform(), revision=subprocess.check_output(["git","rev-parse","HEAD"],text=True).strip(),dirty=bool(subprocess.check_output(["git","status","--porcelain"],text=True).strip()),binarySHA256=hashlib.sha256(binary.read_bytes()).hexdigest(),runnerSHA256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),repetitions=a.repetitions),indent=2))
rows=[]
def invoke(args,log):
    r=subprocess.run([str(binary),*map(str,args)],capture_output=True,text=True,timeout=600)
    log.write_text(r.stdout+r.stderr)
    lines=[x.removeprefix("OBSERVATION_JSON ") for x in r.stdout.splitlines() if x.startswith("OBSERVATION_JSON ")]
    if r.returncode or len(lines)!=1: raise RuntimeError(f"Preserve failed fixture/log {log}; do not replay")
    return json.loads(lines[0])
for case in cases:
    seed=root/(case+"-seed"); invoke(["seed",seed,*CASES[case]],root/(case+"-seed.log"))
    for count in counts:
        for mode in modes:
            for variant in ["independent","shared"]:
                for rep in range(a.repetitions):
                    name=f"{case}-{count}-{mode}-{variant}-{rep}"; target=root/name
                    shutil.copytree(seed,target)
                    row=invoke(["run",target,variant,count,mode],root/(name+".log"));row.update(case=case,repetition=rep)
                    if row["delivered"]!=count: raise RuntimeError("Missing observer state")
                    rows.append(row)
                    with (root/"metrics.jsonl").open("a") as out: out.write(json.dumps(row)+"\n")
                    print(f"{name}: wave={row['waveMS']:.2f}ms scopes={row['executionScopes']}",flush=True)
                    # Retain the modified clone and all auxiliaries as evidence.
summary=["| Case | Observers | Mode | Variant | Samples | Startup median ms | Wave median ms | Wave CPU median ms | Peak median MiB | Scopes min–max |","|---|---:|---|---|---:|---:|---:|---:|---:|---:|"]
for key in dict.fromkeys((r['case'],r['count'],r['mode'],r['variant']) for r in rows):
    subset=[r for r in rows if (r['case'],r['count'],r['mode'],r['variant'])==key]
    fields=[statistics.median(r[f] for r in subset) for f in ['startupMS','waveMS','waveCPU','sampledProcessPeakRSS']]
    scopes=[r['executionScopes'] for r in subset]
    summary.append(f"| {key[0]} | {key[1]} | {key[2]} | {key[3]} | {len(subset)} | {fields[0]:.2f} | {fields[1]:.2f} | {fields[2]:.2f} | {fields[3]/1048576:.2f} | {min(scopes)}–{max(scopes)} |")
(root/"summary.md").write_text("\n".join(summary)+"\n")
