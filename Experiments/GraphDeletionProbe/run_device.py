#!/usr/bin/env python3
"""Run one fresh ordinary private discovery/recovery stage on a signed device host."""
import argparse
import json
from pathlib import Path
import subprocess
import time
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--device', required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
repository = Path(__file__).resolve().parents[2]
output = args.output.resolve()
if output.exists() or output == repository or repository in output.parents:
    parser.error('Use a new external evidence directory.')
output.mkdir(parents=True, mode=0o700)
run = str(uuid.uuid4()).upper()
(output/'run.txt').write_text(run)
stage = 'private-delete'
result = subprocess.run(['python3',str(repository/'Experiments/PublicMirroredProbe/launch_probe.py'),
    '--device',args.device,'--output',str(output/'launch'),'--','--record-transport',stage,run,'owner'],capture_output=True,text=True,timeout=100)
(output/'launch.log').write_text(result.stdout+result.stderr)
if result.returncode: raise SystemExit('Guarded launch failed; preserve this stage without replay.')
base = f'Library/Application Support/GraphEvoLaboratory/AuthoritativeCloud/{run}/owner/'
last = None
deadline = time.monotonic()+900
while time.monotonic() < deadline:
    for name in ['phase.txt',stage+'.report.json']:
        result = subprocess.run(['xcrun','devicectl','device','copy','from','--device',args.device,
            '--domain-type','appDataContainer','--domain-identifier','com.valerioburiani.GraphCKDemo',
            '--source',base+name,'--destination',str(output/name)],capture_output=True,text=True,timeout=25)
        (output/(name+'.copy.log')).write_text(result.stdout+result.stderr)
        if result.returncode: continue
        if name=='phase.txt':
            phase=(output/name).read_text()
            if phase!=last: print(phase,flush=True);last=phase
        else:
            report=json.loads((output/name).read_text());print(json.dumps(report),flush=True)
            raise SystemExit(0 if report['status']=='passed' else 1)
    time.sleep(2)
raise SystemExit('No final report. Preserve the running stage for diagnosis; do not replay.')
