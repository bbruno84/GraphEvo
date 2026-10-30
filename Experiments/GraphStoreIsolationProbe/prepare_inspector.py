#!/usr/bin/env python3
"""Create an external public-API inspector for owned closed GI01 evidence copies."""
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
    parser.error('Use a new inspector directory outside the repository.')
(target/'Sources/Inspector').mkdir(parents=True)
quote = lambda value: json.dumps(str(value), ensure_ascii=False)
(target/'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "GI01Inspector", platforms: [.macOS(.v13)],
    dependencies: [.package(path: '''+quote(library)+''')],
    targets: [.executableTarget(name: "Inspector", dependencies: [.product(name: "GraphEvo", package: '''+quote(library.name.lower())+''')])])
''')
shutil.copyfile(script.with_name('Inspector.swift'),target/'Sources/Inspector/main.swift')
print(target)
