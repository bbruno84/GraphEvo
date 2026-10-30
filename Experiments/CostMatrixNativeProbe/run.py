#!/usr/bin/env python3
"""Continue a fresh one-use seed/identity bootstrap; abort on failure without replaying mutations."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time
import uuid

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--run", required=True, type=uuid.UUID)
parser.add_argument("--output", required=True, type=Path)
args = parser.parse_args()
output = args.output.resolve()
if output.exists() or not str(output).startswith(("/tmp/", "/private/tmp/")):
    parser.error("Use a new external temporary output directory.")
output.mkdir(mode=0o700)
run = str(args.run).upper()
owner = "00008101-00141D1A019A601E"
peer = "00008020-000E2CEC1E38002E"
root = f"Library/Application Support/GraphEvoLaboratory/A6/{run}"
app = "com.valerioburiani.GraphCKDemo"
commands = []

def command(parts, log):
    result = subprocess.run(["xcrun", "devicectl", *parts], capture_output=True, text=True, timeout=45)
    (output / log).write_text(result.stdout + result.stderr)
    commands.append(dict(command=parts, status=result.returncode))
    (output / "commands.json").write_text(json.dumps(commands, indent=2))
    return result.returncode

def copy_from(device, name, destination, log):
    return command(["device", "copy", "from", "--device", device, "--domain-type", "appDataContainer",
                    "--domain-identifier", app, "--source", root + "/" + name,
                    "--destination", str(destination)], log)

def wait(device, stage):
    deadline = time.monotonic() + 720
    attempt = 0
    while time.monotonic() < deadline:
        attempt += 1
        path = output / f"{stage}-report-{attempt}.txt"
        if not copy_from(device, stage + ".txt", path, f"{stage}-copy-{attempt}.log"):
            report = path.read_text()
            if "FAIL " in report:
                raise RuntimeError(f"{stage} failed; retain intent/reports, never replay its write")
            if "PASS " + stage in report:
                print("PASS " + stage, flush=True)
                return
        time.sleep(3)
    raise TimeoutError(f"{stage} timed out; no stage was replayed")

def transfer(source, target, name):
    path = output / name
    if path.exists():
        raise RuntimeError("Transport already exists: " + name)
    if copy_from(source, name, path, name + "-receive.log"):
        raise RuntimeError("Transport receive failed: " + name)
    os.chmod(path, 0o600)
    if command(["device", "copy", "to", "--device", target, "--domain-type", "appDataContainer",
                "--domain-identifier", app, "--source", str(path), "--destination", root + "/" + name], name + "-send.log"):
        raise RuntimeError("Transport send failed: " + name)

def stage(device, name):
    ticket = output / (name + "-reserved.txt")
    with ticket.open("x") as file:
        file.write("Launch reserved; never replay automatically.\n")
    if command(["device", "process", "launch", "--device", device, "--terminate-existing", app,
                "--", "--a6", name, run], name + "-launch.log"):
        raise RuntimeError("Launch failed: " + name)
    wait(device, name)

try:
    # Bootstrap is explicitly performed by the caller once; only observe its retained reports here.
    wait(owner, "seed")
    wait(peer, "identity")
    transfer(owner, peer, "fixture.json")
    transfer(peer, owner, "identity.json")
    stage(owner, "invite")
    transfer(owner, peer, "invitation.json")
    stage(peer, "accept")
    stage(peer, "add")
    transfer(peer, owner, "addition.json")
    stage(owner, "observe-add")
    stage(peer, "replace")
    transfer(peer, owner, "replacement.json")
    stage(owner, "observe-replacement")
    stage(peer, "export-replacement")
    stage(peer, "delete")
    stage(owner, "observe-deletion")
    stage(owner, "owner-cascade")
    stage(peer, "observe-cascade")
    stage(owner, "owner-final-boundary")
    (output / "result.txt").write_text("PASS native lifecycle; no mutation replay.\n")
except Exception as error:
    (output / "result.txt").write_text(type(error).__name__ + ": " + str(error) + "\n")
    raise
