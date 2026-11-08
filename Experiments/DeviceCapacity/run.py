#!/usr/bin/env python3
"""Run one new signed-host capacity stage; never replay a consumed stage."""
import argparse
import json
from pathlib import Path
import subprocess
import time
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--device', required=True)
parser.add_argument('--case', choices=['strings', 'binaries', 'representative', 'delete-control'], required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--source-directory', type=Path)
args = parser.parse_args()
repository = Path(__file__).resolve().parents[2]
output = args.output.resolve()
if output.exists() or output == repository or repository in output.parents:
    parser.error('Use a new evidence directory outside the repository.')
if args.case == 'representative' and not args.source_directory:
    parser.error('Representative trials require an extracted, stopped source directory.')
output.mkdir(parents=True, mode=0o700)
run = str(uuid.uuid4()).upper()
(output/'run.txt').write_text(run)
base = f'Library/Application Support/GraphEvoLaboratory/AuthoritativeCloud/{run}/owner/'
app = 'com.valerioburiani.GraphCKDemo'

def command(arguments, log, timeout=40):
    result = subprocess.run(arguments, capture_output=True, text=True, timeout=timeout)
    (output/log).write_text(result.stdout+result.stderr)
    return result.returncode

if args.case == 'representative':
    sources = list(args.source_directory.glob('*.sqlite'))
    if len(sources) != 1:
        raise SystemExit('Exactly one SQLite source is required.')
    for suffix in ['', '-wal', '-shm']:
        source = Path(str(sources[0])+suffix)
        if not source.is_file(): raise SystemExit('Complete stopped SQLite/WAL/SHM fixture required.')
        if command(['xcrun','devicectl','device','copy','to','--device',args.device,'--domain-type','appDataContainer','--domain-identifier',app,'--source',str(source),'--destination',base+'Legacy.sqlite'+suffix], 'source'+(suffix or '-sqlite')+'.copy.log'):
            raise SystemExit('Source transfer failed; retain this trial and do not launch it.')
launch = ['python3',str(repository/'Experiments/PublicMirroredProbe/launch_probe.py'),'--device',args.device,'--output',str(output/'launch'),'--','--record-transport',args.case,run,'owner']
if command(launch,'launch.log',timeout=100):
    raise SystemExit('Guarded launch failed. Preserve the trial without replay.')
deadline = time.monotonic()+1500
last_phase = None
while time.monotonic() < deadline:
    for name in ['phase.txt', 'metrics.json', 'strings-summary.json', 'mhb-summary.json', 'environment.json', args.case+'.report.json']:
        status = command(['xcrun','devicectl','device','copy','from','--device',args.device,'--domain-type','appDataContainer','--domain-identifier',app,'--source',base+name,'--destination',str(output/name)],name+'.copy.log',timeout=25)
        if status == 0 and name == 'phase.txt':
            phase = (output/name).read_text()
            if phase != last_phase: print(phase,flush=True); last_phase=phase
        if status == 0 and name.endswith('.report.json'):
            report = json.loads((output/name).read_text())
            # The report can arrive after the earlier metrics copy in this poll.
            # Collect the final snapshot only after observing stage completion.
            required = ['metrics.json', 'environment.json']
            if args.case == 'strings': required.append('strings-summary.json')
            if args.case == 'representative': required.append('mhb-summary.json')
            for final_name in required:
                copied = command(['xcrun','devicectl','device','copy','from','--device',args.device,'--domain-type','appDataContainer','--domain-identifier',app,'--source',base+final_name,'--destination',str(output/final_name)],final_name+'.final-copy.log',timeout=25)
                if copied and report['status']=='passed':
                    raise SystemExit('Passing device report, but final measurement collection failed. Retain the trial for read-only collection.')
            print(json.dumps(report),flush=True)
            raise SystemExit(0 if report['status']=='passed' else 1)
    time.sleep(2)
raise SystemExit('No final report by guard. Preserve the process and evidence; do not replay.')
