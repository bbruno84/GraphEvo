#!/usr/bin/env python3
"""Launch a disposable host and require an acknowledgement from the actual new process."""
import argparse
import json
from pathlib import Path
import subprocess
import time
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--device", required=True)
parser.add_argument("--output", required=True, type=Path, help="New external private evidence directory")
parser.add_argument("arguments", nargs=argparse.REMAINDER, help="Host arguments after --")
args = parser.parse_args()
output = args.output.resolve()
repository = Path(__file__).resolve().parents[2]
if output == repository or repository in output.parents or output.exists():
    parser.error("Use a new evidence directory outside the repository.")
output.mkdir(parents=True, mode=0o700)
request = str(uuid.uuid4()).upper()
application = "com.valerioburiani.GraphCKDemo"
host_arguments = args.arguments[1:] if args.arguments[:1] == ["--"] else args.arguments
launch = output / "launch.json"
command = ["xcrun", "devicectl", "device", "process", "launch", "--device", args.device,
           "--terminate-existing", "--json-output", str(launch), application,
           "--", "--launch-ticket", request, *host_arguments]
result = subprocess.run(command, capture_output=True, text=True, timeout=45)
(output / "launch.log").write_text(result.stdout + result.stderr)
if result.returncode:
    raise SystemExit("Launch failed; inspect the private evidence. No stage will be retried.")
process = json.loads(launch.read_text())["result"]["process"]["processIdentifier"]
source = "Library/Application Support/GraphEvoLaboratory/LaunchReceipts/" + request + ".json"
deadline = time.monotonic() + 30
while time.monotonic() < deadline:
    receipt_file = output / "receipt.json"
    result = subprocess.run(["xcrun", "devicectl", "device", "copy", "from", "--device", args.device,
                             "--domain-type", "appDataContainer", "--domain-identifier", application,
                             "--source", source, "--destination", str(receipt_file)],
                            capture_output=True, text=True, timeout=20)
    (output / "receipt-copy.log").write_text(result.stdout + result.stderr)
    if result.returncode == 0:
        receipt = json.loads(receipt_file.read_text())
        if receipt["requestID"] != request or receipt["processIdentifier"] != process:
            raise SystemExit("Launch receipt mismatch. Stop; no stage will be retried.")
        if "sceneDidBecomeActive" in receipt["milestones"]:
            print("PASS host launch acknowledged by its actual process and active scene; inspect the separate stage report.")
            break
    time.sleep(1)
else:
    raise SystemExit("No matching active-scene launch receipt. Retain the process for diagnosis; do not replay the stage.")
