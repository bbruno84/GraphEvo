#!/usr/bin/env python3
"""Build a disposable spool host over an exported committed runtime."""
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
shutil.copyfile(script.with_name("GraphCloudSpoolDeviceProbe.swift"), library / "GraphCloudSpoolDeviceProbe.swift")
controller = args.destination / "GraphEvoDemo/RecordTransportProbe.swift"
s = controller.read_text()
old = '["seed", "update", "delete", "reopen", "read-baseline", "read-update", "read-delete", "audit", "read-audit"]'
new = '["account", "prepare-owner", "resume-owner", "fetch-peer", "apply-peer", "verify-owner", "recover-fresh"]'
if s.count(old) != 1:
    raise RuntimeError("Unexpected base stage dispatcher")
s = s.replace(old, new).replace('GraphCloudTransportDeviceProbe()', 'GraphCloudSpoolDeviceProbe()')
s = s.replace('"--record-transport"', '"--cloud-spool"').replace('GraphEvo T01', 'GraphEvo Spool')
s = s.replace('GraphEvoLaboratory/RecordTransport', 'GraphEvoLaboratory/CloudSpool')
controller.write_text(s)
app = args.destination / "GraphEvoDemo/AppDelegate.swift"
s = app.read_text()
if s.count('"--record-transport"') != 1:
    raise RuntimeError("Unexpected base app dispatcher")
app.write_text(s.replace('"--record-transport"', '"--cloud-spool"'))
