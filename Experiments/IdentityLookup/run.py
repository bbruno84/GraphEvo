#!/usr/bin/env python3
"""Owned fresh local fixtures only; no failed stage or conversion is replayed."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import statistics
import subprocess

CASES = {"small": (100, 1, False), "flat-500": (500, 1, False), "flat-2000": (2000, 1, False),
         "four-graphs": (125, 4, False), "file": (100, 1, True), "fanout": (500, 1, False), "smoke": (16, 1, False)}
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--executable", type=Path, required=True)
parser.add_argument("--cases", default="small,flat-500,flat-2000,four-graphs,file,fanout")
parser.add_argument("--repetitions", type=int, default=5)
args = parser.parse_args()
repo = Path(__file__).resolve().parents[2]
output, binary = args.output.resolve(), args.executable.resolve()
names = args.cases.split(",")
if output.exists() or output == repo or repo in output.parents or not binary.is_file() or args.repetitions < 1 or set(names) - CASES.keys():
    parser.error("Use a new external output, a built executable, positive repetitions and known cases")
output.mkdir(parents=True)
environment = dict(platform=platform.platform(), revision=subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
                   dirty=bool(subprocess.check_output(["git", "status", "--porcelain"], text=True).strip()),
                   binarySHA256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                   runnerSHA256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), repetitions=args.repetitions)
(output / "environment.json").write_text(json.dumps(environment, indent=2))
rows = []
for name in names:
    nodes, graphs, file = CASES[name]
    root = output / name
    def invoke(operation, variant, repetition=0, extra=()):
        result = subprocess.run([str(binary), operation, str(root), variant, *map(str, extra)], capture_output=True, text=True, timeout=600)
        (output / f"{name}-{variant}-{operation}-{repetition}.log").write_text(result.stdout + result.stderr)
        lines = [x.removeprefix("IDENTITY_JSON ") for x in result.stdout.splitlines() if x.startswith("IDENTITY_JSON ")]
        if result.returncode or len(lines) != 1:
            raise RuntimeError(f"{name}/{variant}/{operation} failed; preserve its source/candidate, do not replay")
        row = json.loads(lines[0])
        if operation == "convert" and row.get("sourceUnchanged") is not True:
            raise RuntimeError("Conversion changed its original source")
        if operation in {"audit", "validate"} and row.get("returned") != nodes + 2 + int(file):
            raise RuntimeError("Identity validation did not cover the expected application rows")
        row.update(case=name, repetition=repetition)
        rows.append(row)
        with (output / "metrics.jsonl").open("a") as stream:
            stream.write(json.dumps(row) + "\n")
        print(f"{name}/{variant}/{operation}/{repetition}: {row['elapsedMS']:.2f} ms", flush=True)
    invoke("seed", "files" if file else "fanout" if name == "fanout" else "plain", extra=(nodes, graphs))
    for variant in ["columns", "indexed"]:
        invoke("convert", variant)
    for operation in ["read", "read-edge", "read-action", "missing", "patch"]:
        for variant in ["full", "columns", "indexed"]:
            for repetition in range(1, args.repetitions + 1):
                invoke(operation, variant, repetition)
    for operation in ["audit", "validate"]:
        for variant in ["columns", "indexed"]:
            for repetition in range(1, args.repetitions + 1):
                invoke(operation, variant, repetition)
summary = ["| Case | Variant | Operation | Samples | Median ms | Min–max ms |", "|---|---|---|---:|---:|---:|"]
for case, variant, op in dict.fromkeys((x["case"], x["variant"], x["operation"]) for x in rows):
    values = [x["elapsedMS"] for x in rows if (x["case"], x["variant"], x["operation"]) == (case, variant, op)]
    summary.append(f"| {case} | {variant} | {op} | {len(values)} | {statistics.median(values):.3f} | {min(values):.3f}–{max(values):.3f} |")
(output / "summary.md").write_text("\n".join(summary) + "\n")
