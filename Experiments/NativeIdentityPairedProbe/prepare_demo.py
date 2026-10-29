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
parser.add_argument("--public-api", action="store_true", help="Consume only public schema opening/integrity APIs in the generated probe")
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

if args.public_api:
    replace_once('containerIdentifier: identifier)', 'containerIdentifier: identifier, schema: .nativeIdentity)')
else:
    replace_once("import GraphEvo", "@testable import GraphEvo")
    replace_once("GraphDatabase.openMirrored(privateStoreAt:", "GraphNativeIdentityPairedLaboratory.open(privateStoreAt:")

def save_probe():
    global text
    if args.public_api:
        replace_once('            let stage = arguments[flag + 1]',
                     '            let requestedStage = arguments[flag + 1]\n'
                     '            let stage = ["accept-resume", "accept-after-visibility"].contains(requestedStage) ? "accept" :\n'
                     '                (requestedStage == "observe-replacement-resumed" ? "observe-replacement" :\n'
                     '                 (requestedStage == "observe-deletion-resumed" ? "observe-deletion" : requestedStage))')
        replace_once('        Task { await run() }', '        startProbe()')
        replace_once('    private func log(_ value: String) {',
                     '    private var startRequested = false\n'
                     '    func startProbe() {\n'
                     '        guard !startRequested else { return }; startRequested = true\n'
                     '        Task { await run() }\n'
                     '    }\n'
                     '    private func log(_ value: String) {')
        replace_once('root.appendingPathComponent(stage + ".txt")', 'root.appendingPathComponent(requestedStage + ".txt")')
        replace_once('log("PASS \\(stage); native owner retained for peer observation.")',
                     'log("PASS \\(requestedStage); native owner retained for peer observation.")')
        replace_once('case "invite":', 'case "invite", "invite-resume":')
        replace_once('try write(try await db.invite(identity, to: fixture.a), at: invitationURL, run: run)',
                     'let invitation = try await db.invite(identity, to: fixture.a)\n'
                     '                    if stage == "invite-resume" {\n'
                     '                        let original = try read(GraphInvitation.self, at: invitationURL, run: run)\n'
                     '                        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]\n'
                     '                        guard try encoder.encode(original) == encoder.encode(invitation) else { throw Failure.fixture }\n'
                     '                        try write(invitation, at: root.appendingPathComponent("invitation-resumed.json"), run: run)\n'
                     '                        log("Same recipient/share invitation persisted again; original capability unchanged.")\n'
                     '                    } else { try write(invitation, at: invitationURL, run: run) }')
        import re
        text = re.sub(r'GraphNativeIdentityPairedLaboratory\.validate\(db, graphID: ([^)]+)\)', r'db.validateIntegrity(of: \1)', text)
        if "GraphNativeIdentityPairedLaboratory" in text or "@testable import GraphEvo" in text:
            raise RuntimeError("Public probe must not use internal schema or validation APIs")
    probe.write_text(text)
if args.attachments:
    replace_once("GraphEvoLaboratory/A6/", "GraphEvoLaboratory/NativeIdentityFiles/")
    if args.public_api:
        replace_once('            let fixtureURL = root.appendingPathComponent("fixture.json")',
                     '            log("Both native setup events observed; entering the requested public stage.")\n'
                     '            let fixtureURL = root.appendingPathComponent("fixture.json")')
        for prefix, message in [
                ('                let ownerA = ', 'Both public graphs created.'),
                ('                let small = ', 'Small attachment imported.'),
                ('                let large = ', 'Large attachment imported.'),
                ('                let control = ', 'Control attachment imported; preparing owner boundaries.')]:
            matches = [line for line in text.splitlines() if line.startswith(prefix)]
            if len(matches) != 1:
                raise RuntimeError("Unexpected public A6 checkpoint")
            replace_once(matches[0], matches[0] + '\n                log("' + message + '")')
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
    save_probe()
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
save_probe()
