#!/usr/bin/env python3
"""Validate a copied actual WidgetKit report; this never invokes a provider or writes Graph data."""
import argparse
import json
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('report', type=Path)
parser.add_argument('--run')
parser.add_argument('--value', type=int)
parser.add_argument('--missing-store', action='store_true')
parser.add_argument('--after-unix', type=float, help='Require a report newer than this action timestamp')
args = parser.parse_args()
evidence = json.loads(args.report.read_text())
if not evidence['mirrorRefused']:
    raise SystemExit('FAIL: extension mirroring refusal was not observed.')
if args.after_unix is not None and evidence['date'] + 978307200 <= args.after_unix:
    raise SystemExit('FAIL: the report predates the requested action.')
if args.missing_store:
    if evidence['status'] != 'open-app-first' or evidence.get('value') is not None:
        raise SystemExit('FAIL: expected a missing-store result, not graph data.')
else:
    if args.run is None or args.value is None:
        parser.error('Pass --run and --value, or use --missing-store.')
    if evidence['status'] != 'ready' or evidence.get('runID', '').lower() != args.run.lower() or evidence.get('value') != args.value:
        raise SystemExit('FAIL: the widget did not query the expected run/value.')
    if not evidence['mutationRefused'] or evidence['processID'] == evidence.get('ownerPID'):
        raise SystemExit('FAIL: write refusal or independent-process evidence is missing.')
print('PASS actual widget report: expected state and process/safeguard checks match. Owner liveness and rendering are separate evidence.')
