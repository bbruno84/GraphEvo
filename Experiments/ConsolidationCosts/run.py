#!/usr/bin/env python3
"""Run isolated-process Release screening on new disposable local SQLite fixtures only."""
import argparse
import hashlib
import json
import platform
from pathlib import Path
import statistics
import subprocess
import sys

HERE = Path(__file__).resolve().parent
CASES = [
    dict(name="small", graphs=1, nodes=100, files=0, bytes=0, fileGraph=0),
    dict(name="flat-500", graphs=1, nodes=500, files=0, bytes=0, fileGraph=0),
    dict(name="five-graphs", graphs=5, nodes=100, files=0, bytes=0, fileGraph=0),
    dict(name="two-graphs", graphs=2, nodes=100, files=0, bytes=0, fileGraph=0),
    dict(name="files-here", graphs=1, nodes=100, files=4, bytes=1024**2, fileGraph=0),
    dict(name="files-elsewhere", graphs=2, nodes=100, files=4, bytes=1024**2, fileGraph=1),
    dict(name="one-large-file", graphs=1, nodes=100, files=1, bytes=10*1024**2, fileGraph=0),
    dict(name="four-large-files", graphs=1, nodes=100, files=4, bytes=10*1024**2, fileGraph=0),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="New directory outside the repository; never reused")
    parser.add_argument("--executable", type=Path, required=True, help="Built Release CostProbe executable")
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument("--cases", help="Optional comma-separated case names")
    parser.add_argument("--expect-unrelated-large-files-success", action="store_true",
                        help="Explicit M03 contract: unrelated queries no longer decode file bodies; baseline keeps its expected refusal")
    args = parser.parse_args()
    repository = HERE.parent.parent.resolve()
    output = args.output.resolve()
    if output.exists() or output == repository or repository in output.parents or not args.executable.is_file() or args.repetitions < 1:
        parser.error("Use a new external output directory, a built executable and positive repetitions.")
    requested = set(args.cases.split(",")) if args.cases else {case["name"] for case in CASES}
    unknown = requested - {case["name"] for case in CASES}
    if unknown:
        parser.error("Unknown cases: " + ", ".join(sorted(unknown)))
    output.mkdir(parents=True)
    metadata = {"platform": platform.platform(), "python": platform.python_version(),
                "executable": str(args.executable.resolve()), "repetitions": args.repetitions,
                "expectUnrelatedLargeFilesSuccess": args.expect_unrelated_large_files_success,
                "libraryRevision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repository, text=True).strip(),
                "dirtySource": bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=repository, text=True).strip()),
                "harnessSHA256": {str(path.relative_to(HERE)): hashlib.sha256(path.read_bytes()).hexdigest()
                                   for path in [HERE / "run.py", HERE / "Package.swift", HERE / "Sources/CostProbe/main.swift"]}}
    (output / "environment.json").write_text(json.dumps(metadata, indent=2) + "\n")
    rows = []

    def invoke(case, operation, repetition, budget=32*1024**2, label=None):
        root = output / case["name"]
        command = [str(args.executable.resolve()), operation, str(root), str(root / "configuration.json"), str(budget)]
        result = subprocess.run(command, capture_output=True, text=True, timeout=600 if operation == "seed" else 120)
        name = label or operation
        (output / f'{case["name"]}-{name}-{repetition}.log').write_text(result.stdout + result.stderr)
        lines = [line.removeprefix("COST_JSON ") for line in result.stdout.splitlines() if line.startswith("COST_JSON ")]
        if result.returncode or len(lines) != 1:
            raise RuntimeError(f'{case["name"]}/{name} failed; retain its fixture/log and do not replay the seed')
        row = json.loads(lines[0])
        expected_budget_error = not args.expect_unrelated_large_files_success and case["name"] == "four-large-files" and operation in ("query", "count", "project") and budget == 32*1024**2
        if (row.get("error") == "budgetExceeded(propertyBytes)") != expected_budget_error or (row.get("error") and not expected_budget_error):
            raise RuntimeError(f'Unexpected outcome in {case["name"]}/{name}: {row.get("error")}')
        row.update(repetition=repetition, label=name)
        rows.append(row)
        with (output / "metrics.jsonl").open("a") as stream:
            stream.write(json.dumps(row, sort_keys=True) + "\n")
        print(f'{case["name"]}/{name}/{repetition}: {row["elapsedMS"]:.1f} ms; {row.get("error", "ok")}', flush=True)

    for case in CASES:
        if case["name"] not in requested:
            continue
        root = output / case["name"]
        root.mkdir()
        (root / "configuration.json").write_text(json.dumps(case) + "\n")
        invoke(case, "seed", 0)
        operations = ["fetch", "query", "count", "project", "list", "patch"]
        if case["files"] and case["fileGraph"] == 0:
            operations.insert(-1, "read")
        if case["name"] in ("small", "flat-500", "files-here"):
            operations += ["observe1", "observe8"]
        for operation in operations:
            for repetition in range(1, args.repetitions + 1):
                invoke(case, operation, repetition)
        if case["name"] == "four-large-files":
            for repetition in range(1, args.repetitions + 1):
                invoke(case, "query", repetition, budget=128*1024**2, label="query-raised")
    summary = ["| Case | Operation | Samples | Median ms | Min–max ms | Median open ms | Median whole-process peak MiB | Outcome |",
               "|---|---|---:|---:|---:|---:|---:|---|"]
    for case_name, label in dict.fromkeys((row["name"], row["label"]) for row in rows):
        group = [row for row in rows if row["name"] == case_name and row["label"] == label]
        elapsed = [row["elapsedMS"] for row in group]
        summary.append(f'| {case_name} | {label} | {len(group)} | {statistics.median(elapsed):.2f} | {min(elapsed):.2f}–{max(elapsed):.2f} | '
                       f'{statistics.median(row["openMS"] for row in group):.2f} | '
                       f'{statistics.median(row["sampledPeakResident"] for row in group)/1024**2:.1f} | {group[0].get("error", "ok")} |')
    (output / "summary.md").write_text("\n".join(summary) + "\n")
    print(f"Retained external results: {output}")


if __name__ == "__main__":
    main()
