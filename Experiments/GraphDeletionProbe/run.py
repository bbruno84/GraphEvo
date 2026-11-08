#!/usr/bin/env python3
"""Fresh, bounded macOS process-death and live-holder deletion probes."""
import argparse
import json
from pathlib import Path
import subprocess
import time
import uuid

parser = argparse.ArgumentParser()
parser.add_argument("--binary", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=False)
binary = str(args.binary.resolve())
checks = []

def run(mode, directory, graph):
    result = subprocess.run([binary, mode, str(directory), graph], capture_output=True, text=True, timeout=40)
    (args.output / (directory.name + "-" + mode + ".log")).write_text(result.stdout + result.stderr)
    return result

for stage in ("before", "after", "cleaned"):
    directory = args.output / stage
    graph = str(uuid.uuid4())
    killed = run(stage, directory, graph)
    assert killed.returncode == -9, (stage, killed.returncode)
    # Simulate a quiescent container relocation after process death. Operation
    # evidence and the recorded coordination root move with their relative parent.
    relocated = args.output / (stage + "-relocated")
    directory.rename(relocated)
    resumed = run("resume", relocated, graph)
    assert resumed.returncode == 0, (stage, resumed.stderr[-500:])
    assert not list(relocated.glob(".Graph.sqlite.files-*")), "Owned File content survived terminal cleanup"
    assert (relocated / "Input.bin").read_bytes() == bytes([42]) * (32 * 1024), "Consumer source changed"
    checks.append(stage + ": SIGKILL, relative container relocation and exact terminal recovery passed")

directory = args.output / "live-holder"
graph = str(uuid.uuid4())
assert run("seed", directory, graph).returncode == 0
with (args.output / "holder.log").open("w") as log:
    holder = subprocess.Popen([binary, "hold", str(directory), graph], stdout=log, stderr=log)
    try:
        deadline = time.monotonic() + 20
        while not (directory / "ready").exists():
            assert holder.poll() is None, "Holder failed"
            assert time.monotonic() < deadline, "Holder startup deadline"
            time.sleep(0.1)
        pending = run("delete", directory, graph)
        assert pending.returncode == 0 and "PENDING" in pending.stdout
        assert (directory / "Graph.sqlite").exists()
        (directory / "release").touch()
        assert holder.wait(timeout=10) == 0
        assert run("resume", directory, graph).returncode == 0
        checks.append("Independent live holder deferred destruction; both owners detached; resume passed")
    finally:
        if holder.poll() is None:
            holder.terminate()
            holder.wait(timeout=10)
(args.output / "result.json").write_text(json.dumps({"status": "passed", "checks": checks}, indent=2))
for check in checks:
    print(check)
