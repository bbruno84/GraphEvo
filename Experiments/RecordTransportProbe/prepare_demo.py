#!/usr/bin/env python3
"""Export a pinned runtime plus an external-only bridge into a disposable signed demo."""
import argparse
from pathlib import Path
import json
import shutil
import subprocess
import tarfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("demo", type=Path)
parser.add_argument("destination", type=Path)
args = parser.parse_args()
script = Path(__file__).resolve()
repository = script.parents[2]
destination = args.destination.resolve()
if destination.exists() or repository == destination or repository in destination.parents:
    parser.error("Use a new destination outside the library checkout.")
subprocess.run(["python3", str(script.parent.parent / "A4NativeProbe/prepare_demo.py"), str(args.demo), str(destination)], check=True)
(destination / "GraphEvoDemo/A4NativeProbe.swift").unlink()
library = destination / "Library"
library.mkdir()
archive = destination / "runtime.tar"
subprocess.run(["git", "-C", str(repository), "archive", "--format=tar", "--output", str(archive), "HEAD"], check=True)
with tarfile.open(archive) as source:
    source.extractall(library, filter="data")
archive.unlink()
revision = subprocess.check_output(["git", "-C", str(repository), "rev-parse", "HEAD"], text=True).strip()
(destination / "runtime-revision.txt").write_text(revision + "\n")
shutil.copyfile(script.with_name("GraphCloudTransportDeviceProbe.swift"), library / "Sources/GraphEvo/Experimental/GraphCloudTransportDeviceProbe.swift")
for name in ["AppDelegate.swift", "SceneDelegate.swift", "ProbeLaunchReceipt.swift"]:
    shutil.copyfile(script.parent.parent / "PublicMirroredProbe" / name, destination / "GraphEvoDemo" / name)
shutil.copyfile(script.with_name("RecordTransportProbe.swift"), destination / "GraphEvoDemo/RecordTransportProbe.swift")
project = destination / "GraphEvoDemo.xcodeproj/project.pbxproj"
s = project.read_text()
needle = 'relativePath = ' + json.dumps(str(repository)) + ';'
if s.count(needle) != 1:
    raise RuntimeError("Unexpected package reference in disposable host")
project.write_text(s.replace(needle, 'relativePath = Library;'))
p = destination / "GraphEvoDemo/AppDelegate.swift"
s = p.read_text()
start = s.index('        if args.contains("--native-diagnose") {')
end = s.index('        return true', start)
s = s[:start] + '''        application.isIdleTimerDisabled = true
        if args.contains("--record-transport"), #available(iOS 17, *) {
            let controller = RecordTransportProbeViewController(arguments: args)
            probe = controller
            ProbeLaunchReceipt.mark("probeStartRequested")
            controller.startProbe()
        }
''' + s[end:]
p.write_text(s)
print("Pinned runtime: " + revision)
