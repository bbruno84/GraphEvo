#!/usr/bin/env python3
"""Export the shipping package and inject a local-only storage experiment target."""
import argparse, hashlib, json, shutil, subprocess, tarfile
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__);p.add_argument('destination',type=Path);a=p.parse_args()
here=Path(__file__).resolve().parent;repo=here.parents[1];dst=a.destination.resolve()
if dst.exists() or dst==repo or repo in dst.parents:p.error('Use a new external destination.')
dst.mkdir();archive=dst/'runtime.tar'
subprocess.run(['git','-C',str(repo),'archive','--format=tar','--output',str(archive),'HEAD'],check=True)
with tarfile.open(archive) as t:t.extractall(dst,filter='data')
archive.unlink();target=dst/'TypedPropertyLab';target.mkdir()
for name in ['Probe.swift']:shutil.copyfile(here/name,target/name)
manifest=dst/'Package.swift';s=manifest.read_text();s=s.replace('    targets: [','    targets: [\n        .executableTarget(name: "TypedPropertyProbe", dependencies: ["GraphEvo", "GraphEvoModel"], path: "TypedPropertyLab", swiftSettings: [.swiftLanguageMode(.v6)]),',1);manifest.write_text(s)
rev=subprocess.check_output(['git','-C',str(repo),'rev-parse','HEAD'],text=True).strip()
(dst/'laboratory-pin.json').write_text(json.dumps({'shippingRevision':rev,'overlaySHA256':hashlib.sha256((here/'Probe.swift').read_bytes()).hexdigest()},indent=2)+'\n')
print(dst)
