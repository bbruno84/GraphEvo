#!/usr/bin/env python3
"""Prepare an external synthetic MF10 first-create proof using the pinned demo exporter."""
import argparse
from pathlib import Path
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("demo", type=Path)
parser.add_argument("destination", type=Path)
parser.add_argument("--activation", action="store_true", help="Use the full production-activation bridge instead of the standalone claim prerequisite")
args = parser.parse_args()
here = Path(__file__).resolve().parent
subprocess.run(["python3", str(here.parent / "RecordTransportProbe/prepare_demo.py"),
                str(args.demo), str(args.destination)], check=True)
shutil.copyfile(here / ("ActivationProbe.swift" if args.activation else "ClaimProbe.swift"), args.destination / "GraphEvoDemo/RecordTransportProbe.swift")
if args.activation:
    shutil.copyfile(here / "GraphCloudActivationDeviceProbe.swift", args.destination / "Library/Sources/GraphEvo/Experimental/GraphCloudActivationDeviceProbe.swift")
