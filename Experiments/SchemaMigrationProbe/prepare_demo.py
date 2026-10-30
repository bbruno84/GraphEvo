#!/usr/bin/env python3
"""Prepare a disposable schema migration host, preserving the configured source demo."""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('demo', type=Path)
parser.add_argument('destination', type=Path)
args = parser.parse_args()
script = Path(__file__).resolve()
subprocess.run([sys.executable, str(script.parent.parent/'PublicMirroredProbe/prepare_demo.py'), str(args.demo), str(args.destination)], check=True)
shutil.copyfile(script.with_name('SchemaMigrationProbe.swift'), args.destination/'GraphEvoDemo/SchemaMigrationProbe.swift')
p = args.destination/'GraphEvoDemo/AppDelegate.swift'
s = p.read_text()
needle = '        if args.contains("--native-diagnose") {'
assert s.count(needle) == 1
s = s.replace(needle, '''        if args.contains("--schema"), #available(iOS 17, *) {
            let controller = SchemaMigrationProbeViewController(arguments: args)
            probe = controller
            ProbeLaunchReceipt.mark("probeStartRequested")
            controller.startProbe()
        } else if args.contains("--native-diagnose") {''', 1)
p.write_text(s)
