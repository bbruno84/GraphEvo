#!/usr/bin/env python3
"""Prepare a disposable configured demo for read-only C02 metadata checks without editing its source checkout."""
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
subprocess.run([sys.executable, str(script.parent.parent / "A4NativeProbe/prepare_demo.py"), str(args.demo), str(args.destination)], check=True)
shutil.copyfile(script.with_name("C02NativeProbe.swift"), args.destination / "GraphEvoDemo/C02NativeProbe.swift")
scene = args.destination / "GraphEvoDemo/SceneDelegate.swift"
needle = 'if ProcessInfo.processInfo.arguments.contains("--a4") {'
text = scene.read_text()
if text.count(needle) != 1:
    raise RuntimeError("Unexpected A4 launch dispatcher in disposable copy")
scene.write_text(text.replace(needle, 'if ProcessInfo.processInfo.arguments.contains("--c02") {\n'
    '            root = C02NativeProbeViewController(arguments: ProcessInfo.processInfo.arguments)\n'
    '        } else '+needle, 1))
