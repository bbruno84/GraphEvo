#!/usr/bin/env python3
"""Prepare a disposable, pinned T07 device host. Generated output stays external."""
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
shutil.copyfile(script.with_name("GraphZoneSharingDeviceProbe.swift"), library / "GraphZoneSharingDeviceProbe.swift")
controller = args.destination / "GraphEvoDemo/RecordTransportProbe.swift"
s = controller.read_text().replace('GraphCloudTransportDeviceProbe()', 'GraphZoneSharingDeviceProbe()')
s = s.replace('["seed", "update", "delete", "reopen", "read-baseline", "read-update", "read-delete", "audit", "read-audit"]',
              '["identity", "seed", "accept", "peer-edit", "owner-edit", "observe-owner", "observe-peer", "recover"]')
s = s.replace('"--record-transport"', '"--zone-sharing"').replace('GraphEvo T01', 'GraphEvo T07')
s = s.replace('GraphEvoLaboratory/RecordTransport', 'GraphEvoLaboratory/ZoneSharing')
controller.write_text(s)
app = args.destination / "GraphEvoDemo/AppDelegate.swift"
app.write_text(app.read_text().replace('"--record-transport"', '"--zone-sharing"'))
