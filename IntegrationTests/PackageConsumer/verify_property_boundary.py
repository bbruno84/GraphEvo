#!/usr/bin/env python3
"""Check rejected public property APIs against built consumer modules."""
import argparse
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--modules", type=Path, required=True)
args = parser.parse_args()
fixtures = Path(__file__).resolve().parent / "CompileFailures"
for name, symbol in [("RawData", "graphValue"), ("BinaryCase", "data"), ("EncodedCase", "encoded")]:
    result = subprocess.run(
        ["xcrun", "swiftc", "-swift-version", "6", "-typecheck", "-I", str(args.modules), str(fixtures / (name + ".swift"))],
        capture_output=True, text=True,
    )
    if result.returncode == 0 or ("no member '" + symbol + "'") not in result.stderr:
        raise SystemExit(name + " did not fail at the intended public API boundary:\n" + result.stderr)
    print("PASS rejected public property API: " + name)
