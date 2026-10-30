#!/usr/bin/env python3
"""Prepare a disposable public-API GI01 host without changing the configured demo."""
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
shutil.copyfile(script.with_name('GraphStoreIsolationProbe.swift'), args.destination/'GraphEvoDemo/GraphStoreIsolationProbe.swift')
p = args.destination/'GraphEvoDemo/AppDelegate.swift'
s = p.read_text()
needle = '        if args.contains("--native-diagnose") {'
assert s.count(needle) == 1
p.write_text(s.replace(needle, '''        if args.contains("--graph-isolation") {
            let controller = GraphStoreIsolationProbeViewController(arguments: args)
            probe = controller
            ProbeLaunchReceipt.mark("probeStartRequested")
            controller.startProbe()
        } else if args.contains("--native-diagnose") {''', 1))
