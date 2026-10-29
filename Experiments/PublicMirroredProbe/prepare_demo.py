#!/usr/bin/env python3
"""Prepare a public-only A6 paired consumer and a private-only public schema probe."""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("demo", type=Path)
parser.add_argument("destination", type=Path)
args = parser.parse_args()
script = Path(__file__).resolve()
subprocess.run([sys.executable, str(script.parent.parent / "NativeIdentityPairedProbe/prepare_demo.py"),
                str(args.demo), str(args.destination), "--attachments", "--public-api"], check=True)
for name in ["PublicMirroredProbe.swift", "PublicMirroredDiagnostics.swift", "AppDelegate.swift", "SceneDelegate.swift"]:
    shutil.copyfile(script.with_name(name), args.destination / ("GraphEvoDemo/" + name))
