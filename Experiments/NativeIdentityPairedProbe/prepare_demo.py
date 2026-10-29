#!/usr/bin/env python3
"""Prepare a disposable A5 host selecting only the internal fresh native paired layout."""
import argparse
from pathlib import Path
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("demo", type=Path)
parser.add_argument("destination", type=Path)
args = parser.parse_args()
script = Path(__file__).resolve()
subprocess.run([sys.executable, str(script.parent.parent / "A5NativeProbe/prepare_demo.py"),
                str(args.demo), str(args.destination)], check=True)
probe = args.destination / "GraphEvoDemo/A5NativeProbe.swift"
text = probe.read_text()

def replace_once(old, new):
    global text
    if text.count(old) != 1:
        raise RuntimeError("Unexpected A5 source: " + old)
    text = text.replace(old, new, 1)

replace_once("import GraphEvo", "@testable import GraphEvo")
replace_once("GraphDatabase.openMirrored(privateStoreAt:", "GraphNativeIdentityPairedLaboratory.open(privateStoreAt:")
replace_once("GraphEvoLaboratory/A5/", "GraphEvoLaboratory/NativeIdentity/")
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
             '["seed", "identity", "invite", "reinvite", "read-only", "restore-rw", "revoke", '
             '"participant-add", "participant-details", "read-write-probe", "recover-patch", "resume-writer"].contains(stage)')
probe.write_text(text)
