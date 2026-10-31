#!/usr/bin/env python3
"""Build a disposable asset host over an exported committed runtime."""
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
shutil.copyfile(script.with_name("GraphCloudAssetDeviceProbe.swift"), library / "GraphCloudAssetDeviceProbe.swift")
controller = args.destination / "GraphEvoDemo/RecordTransportProbe.swift"
s = controller.read_text()
old = '["seed", "update", "delete", "reopen", "read-baseline", "read-update", "read-delete", "audit", "read-audit"]'
new = '["seed", "seed-remaining", "read-baseline", "prepare-peer", "owner-replace", "resolve-peer", "resolve-remaining", "observe-owner", "reopen-peer", "delete-owner", "read-deleted", "read-final"]'
if s.count(old) != 1:
    raise RuntimeError("Unexpected base stage dispatcher")
s = s.replace(old, new).replace('GraphCloudTransportDeviceProbe()', 'GraphCloudAssetDeviceProbe()')
s = s.replace('"--record-transport"', '"--cloud-assets"').replace('GraphEvo T01', 'GraphEvo T04')
s = s.replace('GraphEvoLaboratory/RecordTransport', 'GraphEvoLaboratory/CloudAssets')
controller.write_text(s)
app = args.destination / "GraphEvoDemo/AppDelegate.swift"
s = app.read_text()
if s.count('"--record-transport"') != 1:
    raise RuntimeError("Unexpected base app dispatcher")
app.write_text(s.replace('"--record-transport"', '"--cloud-assets"'))
