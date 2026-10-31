#!/usr/bin/env python3
"""Export the committed T08 runtime into a disposable signed host, outside the checkout."""
import argparse
from pathlib import Path
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("demo", type=Path)
parser.add_argument("destination", type=Path)
args = parser.parse_args()
script = Path(__file__).resolve()
subprocess.run(["python3", str(script.parent.parent / "RecordTransportProbe/prepare_demo.py"),
                str(args.demo), str(args.destination)], check=True)
library = args.destination / "Library/Sources/GraphEvo/Experimental"
(library / "GraphCloudTransportDeviceProbe.swift").unlink()
shutil.copyfile(script.with_name("GraphSharingLifecycleDeviceProbe.swift"), library / "GraphSharingLifecycleDeviceProbe.swift")
controller = args.destination / "GraphEvoDemo/RecordTransportProbe.swift"
s = controller.read_text().replace('GraphCloudTransportDeviceProbe()', 'GraphSharingLifecycleDeviceProbe()')
s = s.replace('["seed", "update", "delete", "reopen", "read-baseline", "read-update", "read-delete", "audit", "read-audit"]',
              '["identity", "seed", "accept", "pending", "downgrade", "read-only", "revoke", "revoke-start", "recover-purge", "reinvite", "rejoin", "leave", "stop", "stop-all", "audit"]')
s = s.replace('"--record-transport"', '"--sharing-lifecycle"').replace('GraphEvo T01', 'GraphEvo T08')
s = s.replace('GraphEvoLaboratory/RecordTransport', 'GraphEvoLaboratory/SharingLifecycle')
controller.write_text(s)
app = args.destination / "GraphEvoDemo/AppDelegate.swift"
app.write_text(app.read_text().replace('"--record-transport"', '"--sharing-lifecycle"'))
