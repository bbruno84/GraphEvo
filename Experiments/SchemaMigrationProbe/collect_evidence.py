#!/usr/bin/env python3
"""Compare protected copied reports; never invokes a device or changes a Graph store."""
import argparse
import base64
import json
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--baseline', required=True, type=Path)
parser.add_argument('--label')
parser.add_argument('--stage-only')
parser.add_argument('--version', type=int)
parser.add_argument('--handlers', nargs='*')
parser.add_argument('reports', nargs='+', type=Path)
args = parser.parse_args()


def read(path):
    envelope = json.loads(path.read_text())
    value = envelope['value']
    if isinstance(value, dict):
        if value.get('succeeded') is not True:
            raise SystemExit('FAIL: a stage report records failure.')
        rows = value['rows']
    else:
        rows = value
    if not isinstance(rows, list) or len(rows) != 4 or len({row['id'] for row in rows}) != 4:
        raise SystemExit('FAIL: expected four distinct fixture rows.')
    for row in rows:
        base64.b64decode(row['bytes'], validate=True)
    return envelope, sorted(rows, key=lambda row: row['id'])


baseline, expected = read(args.baseline)
keys = ['kind', 'id', 'type', 'bytes', 'tags', 'groups', 'date', 'subjects', 'objects']
for report in args.reports:
    envelope, rows = read(report)
    launch_path, receipt_path = report.parent / 'launch.json', report.parent / 'receipt.json'
    if not launch_path.is_file() or not receipt_path.is_file():
        raise SystemExit('FAIL: keep the acknowledged launch and receipt beside each stage report.')
    process = json.loads(launch_path.read_text())['result']['process']['processIdentifier']
    receipt = json.loads(receipt_path.read_text())
    if envelope['value']['processID'] != process or receipt['processIdentifier'] != process or 'sceneDidBecomeActive' not in receipt['milestones']:
        raise SystemExit('FAIL: stage report is not bound to the acknowledged active process.')
    ticket = envelope['value'].get('launchTicket')
    if ticket is not None and ticket != receipt['requestID']:
        raise SystemExit('FAIL: stage launch ticket differs from its receipt.')
    if envelope['run'] != baseline['run']:
        raise SystemExit('FAIL: run identity differs.')
    if [{key: row[key] for key in keys} for row in rows] != [{key: row[key] for key in keys} for row in expected]:
        raise SystemExit('FAIL: fixture identities, topology, metadata or binary content differ.')
    if args.label is not None and not all(row['label'] == args.label for row in rows):
        raise SystemExit('FAIL: expected label was not independently observed.')
    if args.stage_only is not None and not all(row.get('stageOnly') == args.stage_only for row in rows):
        raise SystemExit('FAIL: handler-only value differs.')
    if args.version is not None and not all(row.get('dataVersion') == args.version
            and row.get('graphProjection') == envelope['run'] and row.get('nodeProjection') == row['id'] for row in rows):
        raise SystemExit('FAIL: expected native version/identity projections are absent or differ.')
    if args.handlers is not None and envelope['value'].get('handlers') != args.handlers:
        raise SystemExit('FAIL: expected native handler sequence differs.')
print('PASS copied report comparison: exact fixture preservation and requested assertions. Acknowledged process binding matches; native/replica independence still depends on the separate protocol evidence.')
