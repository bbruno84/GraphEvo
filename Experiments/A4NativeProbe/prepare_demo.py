#!/usr/bin/env python3
"""Prepare a disposable demo copy against this checkout without editing the user's demo."""
import argparse
import json
from pathlib import Path
import re
import shutil

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("demo", type=Path, help="Existing configured GraphEvoDemo checkout")
parser.add_argument("destination", type=Path, help="New disposable directory; must not exist")
args = parser.parse_args()
source = args.demo.resolve()
target = args.destination.resolve()
if target.exists() or not (source / "GraphEvoDemo.xcodeproj/project.pbxproj").is_file():
    parser.error("The source must be a demo checkout and the destination must not exist.")
if source == target or source in target.parents:
    parser.error("The disposable destination must be outside the original demo checkout.")
library = Path(__file__).resolve().parents[2]
project = source / "GraphEvoDemo.xcodeproj/project.pbxproj"
pattern = r'isa = XCRemoteSwiftPackageReference;\s*repositoryURL = "https://github.com/bbruno84/GraphEvo.git";\s*requirement = \{.*?\};'
replacement = 'isa = XCLocalSwiftPackageReference;\n\t\t\trelativePath = ' + json.dumps(str(library)) + ';'
contents, count = re.subn(pattern, replacement, project.read_text(), flags=re.S)
if count != 1:
    parser.error("Expected one GraphEvo remote package reference; inspect the demo project first.")
scene = source / "GraphEvoDemo/SceneDelegate.swift"
original = scene.read_text()
needle = "if let request = V09Request.parse"
if original.count(needle) != 1:
    parser.error("Expected the known laboratory launch dispatcher; inspect SceneDelegate first.")
shutil.copytree(source, target, ignore=shutil.ignore_patterns(".git", ".build", "build", "DerivedData", ".DS_Store"))
(target / "GraphEvoDemo.xcodeproj/project.pbxproj").write_text(contents.replace("XCRemoteSwiftPackageReference", "XCLocalSwiftPackageReference"))
shutil.copyfile(Path(__file__).with_name("A4NativeProbe.swift"), target / "GraphEvoDemo/A4NativeProbe.swift")
(target / "GraphEvoDemo/SceneDelegate.swift").write_text(original.replace(needle,
    'if ProcessInfo.processInfo.arguments.contains("--a4") {\n'
    '            root = A4NativeProbeViewController(arguments: ProcessInfo.processInfo.arguments)\n'
    '        } else if let request = V09Request.parse', 1))
print(target)
