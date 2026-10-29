#!/usr/bin/env python3
"""Prepare an explicitly instrumented disposable library/host, never the shipping checkout."""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("demo", type=Path)
parser.add_argument("destination", type=Path, help="New external private directory")
args = parser.parse_args()
script = Path(__file__).resolve()
repository = script.parents[2]
destination = args.destination.resolve()
if destination.exists() or destination == repository or repository in destination.parents:
    parser.error("Use a new external directory.")
if destination == args.demo.resolve() or args.demo.resolve() in destination.parents:
    parser.error("Keep the configured demo unchanged.")
destination.mkdir(parents=True, mode=0o700)
library = destination / "Library"
library.mkdir()
files = subprocess.check_output(["git", "-C", str(repository), "ls-files", "-z"])
for entry in files.decode().split("\0"):
    if not entry:
        continue
    source = repository / entry
    if source.is_file():
        target = library / entry
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
subprocess.run(["patch", "--batch", "--fuzz=0", "-p1", "-d", str(library),
                "-i", str(script.with_name("invitation-trace.patch"))], check=True)
host = destination / "Host"
subprocess.run([sys.executable, str(script.with_name("prepare_demo.py")), str(args.demo), str(host)], check=True)
project = host / "GraphEvoDemo.xcodeproj/project.pbxproj"
text = project.read_text()
if text.count(str(repository)) != 1:
    raise RuntimeError("Expected exactly one local library reference in the disposable host.")
project.write_text(text.replace(str(repository), str(library)))
print("Prepared an instrumented external copy; this is not an unmodified public-consumer result.")
