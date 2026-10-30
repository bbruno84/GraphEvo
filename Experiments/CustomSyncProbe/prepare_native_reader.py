#!/usr/bin/env python3
"""Prepare an external lab model exporter and independent Core Data reader."""
import argparse
import json
from pathlib import Path
import shutil
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('destination', type=Path)
args = parser.parse_args()
script = Path(__file__).resolve()
library = script.parents[2]
target = args.destination.resolve()
if target.exists() or target == library or library in target.parents:
    parser.error('Use a new directory outside the repository.')
quote = lambda value: json.dumps(str(value), ensure_ascii=False)
target.mkdir(parents=True)
(target/'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "CS01NativeReader", platforms: [.macOS(.v13)],
    dependencies: [.package(path: '''+quote(library)+''')],
    targets: [
      .executableTarget(name: "ModelExporter", dependencies: [.product(name: "GraphEvo", package: '''+quote(library.name.lower())+''')]),
      .executableTarget(name: "CoreDataReader", dependencies: [])
    ])
''')
for name in ['ModelExporter','CoreDataReader']:
    directory = target/'Sources'/name
    directory.mkdir(parents=True)
    shutil.copyfile(script.with_name(name+'.swift'),directory/'main.swift')
print(target)
