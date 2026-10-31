#!/usr/bin/env python3
"""Read a bounded stage report; never relaunch or replay the stage."""
import argparse
import json
from pathlib import Path
import subprocess
import time
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--device", required=True)
parser.add_argument("--run", required=True, type=uuid.UUID)
parser.add_argument("--stage", required=True, choices=["seed", "update", "delete", "reopen", "read-baseline", "read-update", "read-delete", "audit", "read-audit"])
parser.add_argument("--replica", required=True, choices=["owner", "peer", "fresh"])
parser.add_argument("--output", required=True, type=Path)
args = parser.parse_args()
output = args.output.resolve()
repository = Path(__file__).resolve().parents[2]
if output.exists() or output == repository or repository in output.parents:
    parser.error("Use a new output directory outside the repository.")
output.mkdir(mode=0o700, parents=True)
source = f"Library/Application Support/GraphEvoLaboratory/RecordTransport/{str(args.run).upper()}/{args.replica}/{args.stage}.report.json"
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
            raise SystemExit("Stage failed. Retain original state; no stage replay.")
        break
    time.sleep(1)
else:
    raise SystemExit("No report within the read deadline. Inspect original process/state; no stage replay.")
