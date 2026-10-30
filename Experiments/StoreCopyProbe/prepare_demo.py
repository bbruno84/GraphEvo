#!/usr/bin/env python3
"""Prepare a disposable MC01 host without modifying the configured source demo."""
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
shutil.copyfile(script.with_name('StoreCopyProbe.swift'), args.destination/'GraphEvoDemo/StoreCopyProbe.swift')
p = args.destination/'GraphEvoDemo/AppDelegate.swift'
s = p.read_text()
needle = '        if args.contains("--native-diagnose") {'
assert s.count(needle) == 1
p.write_text(s.replace(needle, '''        if args.contains("--store-copy") {
            let controller = StoreCopyProbeViewController(arguments: args)
            probe = controller
            ProbeLaunchReceipt.mark("probeStartRequested")
            controller.startProbe()
        } else if args.contains("--native-diagnose") {''', 1))
