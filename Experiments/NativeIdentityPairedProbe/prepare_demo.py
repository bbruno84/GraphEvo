#!/usr/bin/env python3
"""Prepare a disposable A5/A6 host selecting only the internal fresh native paired layout."""
import argparse
from pathlib import Path
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("demo", type=Path)
parser.add_argument("destination", type=Path)
parser.add_argument("--attachments", action="store_true", help="Prepare the separate native-column A6 file lifecycle host")
args = parser.parse_args()
script = Path(__file__).resolve()
suite = "A6" if args.attachments else "A5"
subprocess.run([sys.executable, str(script.parent.parent / (suite + "NativeProbe/prepare_demo.py")),
                str(args.demo), str(args.destination)], check=True)
probe = args.destination / ("GraphEvoDemo/" + suite + "NativeProbe.swift")
text = probe.read_text()

def replace_once(old, new):
    global text
    if text.count(old) != 1:
        raise RuntimeError("Unexpected " + suite + " source: " + old)
    text = text.replace(old, new, 1)

replace_once("import GraphEvo", "@testable import GraphEvo")
replace_once("GraphDatabase.openMirrored(privateStoreAt:", "GraphNativeIdentityPairedLaboratory.open(privateStoreAt:")
if args.attachments:
    replace_once("GraphEvoLaboratory/A6/", "GraphEvoLaboratory/NativeIdentityFiles/")
    replace_once('log("Prepared A with 512-byte/10-MiB files and personal B control in distinct boundaries.")',
                 'guard try await GraphNativeIdentityPairedLaboratory.validate(db, graphID: a.id) == 3,\n'
                 '                      try await GraphNativeIdentityPairedLaboratory.validate(db, graphID: b.id) == 2 else { throw Failure.fixture }\n'
                 '                log("Prepared A with 512-byte/10-MiB files and personal B control in distinct boundaries.")')
    replace_once('guard count == (deletion ? 1 : 2) + (addition == nil ? 0 : 1) else { throw Failure.fixture }',
                 'guard count == (deletion ? 1 : 2) + (addition == nil ? 0 : 1),\n'
                 '                      try await GraphNativeIdentityPairedLaboratory.validate(db, graphID: fixture.a) == count + 1 else { throw Failure.fixture }')
    replace_once('let other = try await db.inspectMirroring(for: fixture.b)',
                 'guard try await GraphNativeIdentityPairedLaboratory.validate(db, graphID: fixture.b) == 2 else { throw Failure.fixture }\n'
                 '                    let other = try await db.inspectMirroring(for: fixture.b)')
    replace_once('            peak = max(peak, memory())',
                 '            if ["observe-cascade", "owner-final-boundary"].contains(stage) {\n'
                 '                let fixture = try read(Fixture.self, at: fixtureURL, run: run)\n'
                 '                guard try await GraphNativeIdentityPairedLaboratory.validate(db, graphID: fixture.a) == 0 else { throw Failure.fixture }\n'
                 '            }\n'
                 '            peak = max(peak, memory())')
    probe.write_text(text)
    sys.exit(0)
replace_once("GraphEvoLaboratory/A5/", "GraphEvoLaboratory/NativeIdentity/")
replace_once('case "invite", "reinvite":', 'case "invite", "reinvite", "reinvite-after-revoke":')
replace_once('case "recover-patch":', 'case "recover-patch", "recover-after-conflict":')
replace_once('guard first.zoneName != second.zoneName else { throw Failure.fixture }',
             'guard first.zoneName != second.zoneName,\n'
             '                      try await GraphNativeIdentityPairedLaboratory.validate(db, graphID: a.id) == 5,\n'
             '                      try await GraphNativeIdentityPairedLaboratory.validate(db, graphID: b.id) == 5 else { throw Failure.fixture }')
replace_once('guard all.count == count, Set(all.map(\\.id)) == Set(expected) else { throw Failure.fixture }',
             'guard all.count == count, Set(all.map(\\.id)) == Set(expected),\n'
             '                      try await GraphNativeIdentityPairedLaboratory.validate(db, graphID: fixture.a) == count else { throw Failure.fixture }')
replace_once('guard controlCount == 5 else { throw Failure.fixture }',
             'guard controlCount == 5, try await GraphNativeIdentityPairedLaboratory.validate(db, graphID: fixture.b) == 5 else { throw Failure.fixture }')
replace_once('["participant-add", "participant-details", "read-write-probe", "recover-patch", "resume-writer"].contains(stage)',
             '["seed", "identity", "invite", "reinvite", "reinvite-after-revoke", "read-only", "restore-rw", "revoke", '
             '"participant-add", "participant-details", "read-write-probe", "recover-patch", "recover-after-conflict", "resume-writer"].contains(stage)')
probe.write_text(text)
