#!/usr/bin/env python3
"""Build a disposable conflict host over an exported committed runtime."""
import argparse
from pathlib import Path
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("demo", type=Path)
parser.add_argument("destination", type=Path)
args = parser.parse_args()
script = Path(__file__).resolve()
base = script.parent.parent / "RecordTransportProbe"
subprocess.run(["python3", str(base / "prepare_demo.py"), str(args.demo), str(args.destination)], check=True)
library = args.destination / "Library/Sources/GraphEvo/Experimental"
(library / "GraphCloudTransportDeviceProbe.swift").unlink()
shutil.copyfile(script.with_name("GraphCloudPolicyDeviceProbe.swift"), library / "GraphCloudPolicyDeviceProbe.swift")
controller = args.destination / "GraphEvoDemo/RecordTransportProbe.swift"
s = controller.read_text()
old = '["seed", "update", "delete", "reopen", "read-baseline", "read-update", "read-delete", "audit", "read-audit"]'
new = '["seed", "read-baseline", "prepare-peer", "owner-compete", "resolve-peer", "reopen-peer", "observe-owner", "read-final"]'
if s.count(old) != 1:
    raise RuntimeError("Unexpected base stage dispatcher")
s = s.replace(old, new).replace('GraphCloudTransportDeviceProbe()', 'GraphCloudPolicyDeviceProbe()')
s = s.replace('"--record-transport"', '"--conflict-policy"').replace('GraphEvo T01', 'GraphEvo T03')
s = s.replace('GraphEvoLaboratory/RecordTransport', 'GraphEvoLaboratory/ConflictPolicies')
controller.write_text(s)
app = args.destination / "GraphEvoDemo/AppDelegate.swift"
s = app.read_text()
if s.count('"--record-transport"') != 1:
    raise RuntimeError("Unexpected base app dispatcher")
app.write_text(s.replace('"--record-transport"', '"--conflict-policy"'))
