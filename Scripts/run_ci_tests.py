#!/usr/bin/env python3
"""Explicit CI profiles; no inferred file-based test selection or shell commands."""
import argparse
import json
import subprocess
from pathlib import Path

CAPACITY_TEST = "twoThousandRecordNativeSortFitsTheUnchangedStepBudget"
V2_TARGETS = ("GraphEvoStoreTests", "GraphEvoRuntimeTests", "GraphEvoModelTests")


def command(profile, platform, destination=None, result_bundle=None):
    if profile not in ("v2", "full") or platform not in ("macos", "ios"):
        raise ValueError("Unknown CI profile or platform")
    if platform == "macos":
        args = ["swift", "test"]
        if profile == "v2":
            args += ["--filter", "GraphEvo(Store|Runtime|Model)Tests", "--skip", CAPACITY_TEST]
        return args
    if not destination or not result_bundle:
        raise ValueError("iOS requires a destination and result bundle")
    args = ["xcodebuild", "-quiet", "test", "-scheme", "GraphEvo",
            "-destination", destination, "-resultBundlePath", result_bundle,
            "CODE_SIGNING_ALLOWED=NO"]
    if profile == "v2":
        args += ["-only-testing:" + target for target in V2_TARGETS]
        args += ["-skip-testing:GraphEvoStoreTests/GraphTypedQueryTests/" + CAPACITY_TEST + "()"]
    return args


def validate_summary(summary):
    if summary.get("passedTests", 0) <= 0 or summary.get("failedTests", 0) != 0:
        raise ValueError("CI requires executed passing tests and zero failures")
    return {key: summary.get(key) for key in ("passedTests", "failedTests", "skippedTests", "totalTestCount")}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", choices=("v2", "full"), required=True)
    parser.add_argument("--platform", choices=("macos", "ios"), required=True)
    parser.add_argument("--destination")
    parser.add_argument("--result-bundle")
    parser.add_argument("--dry-run", action="store_true")
    options = parser.parse_args()
    try:
        args = command(options.profile, options.platform, options.destination, options.result_bundle)
    except ValueError as error:
        parser.error(str(error))
    print(json.dumps({"profile": options.profile, "platform": options.platform, "command": args}), flush=True)
    if options.dry_run:
        return 0
    status = subprocess.call(args)
    if status == 0 and options.platform == "ios":
        raw = subprocess.check_output(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", options.result_bundle])
        Path(options.result_bundle).with_suffix(".summary.json").write_bytes(raw)
        print(json.dumps(validate_summary(json.loads(raw))), flush=True)
    return status


if __name__ == "__main__":
    raise SystemExit(main())
