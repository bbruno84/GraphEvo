#!/usr/bin/env python3
"""Collect one immutable MF10 stage report without relaunching or replaying it."""
import argparse
import json
from pathlib import Path
import subprocess
import time
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--device", required=True)
parser.add_argument("--run", required=True, type=uuid.UUID)
parser.add_argument("--stage", required=True, choices=["prepare", "seed", "publish", "verify", "recover-peer", "refresh-peer", "verify-account", "update-owner"])
parser.add_argument("--replica", required=True, choices=["owner", "peer", "fresh", "contender"])
parser.add_argument("--output", required=True, type=Path)
args = parser.parse_args()
output = args.output.resolve()
repository = Path(__file__).resolve().parents[2]
if output.exists() or output == repository or repository in output.parents:
    parser.error("Use a new evidence directory outside the repository.")
output.mkdir(parents=True, mode=0o700)
source = f"Library/Application Support/GraphEvoLaboratory/AuthoritativeCloud/{str(args.run).upper()}/{args.replica}/{args.stage}.report.json"
deadline = time.monotonic() + 45
while time.monotonic() < deadline:
    result = subprocess.run(["xcrun", "devicectl", "device", "copy", "from", "--timeout", "15", "--device", args.device,
        "--domain-type", "appDataContainer", "--domain-identifier", "com.valerioburiani.GraphCKDemo",
        "--source", source, "--destination", str(output / "report.json")], capture_output=True, text=True, timeout=20)
    (output / "copy.log").write_text(result.stdout + result.stderr)
    if result.returncode == 0:
        report = json.loads((output / "report.json").read_text())
        if report.get("stage") != args.stage or report.get("replica") != args.replica:
            raise SystemExit("Report identity mismatch. Retain evidence; no stage replay.")
        print(json.dumps(report, indent=2))
        if report.get("status") != "passed":
            raise SystemExit("Stage failed. Inspect original state; no stage replay.")
        break
    time.sleep(1)
else:
    raise SystemExit("No report within deadline. Inspect original process; no stage replay.")
