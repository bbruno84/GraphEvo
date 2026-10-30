#!/usr/bin/env python3
"""Prepare the public S01 sharing/file host with independently empty replica paths."""
import argparse
from pathlib import Path
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('demo', type=Path)
parser.add_argument('destination', type=Path)
args = parser.parse_args()
script = Path(__file__).resolve()
subprocess.run([sys.executable, str(script.parent.parent/'PublicMirroredProbe/prepare_demo.py'),
                str(args.demo), str(args.destination)], check=True)
probe = args.destination/'GraphEvoDemo/A6NativeProbe.swift'
text = probe.read_text()

def replace(old, new):
    global text
    if text.count(old) != 1:
        raise RuntimeError('Unexpected public host source; stop before launching a stage.')
    text = text.replace(old, new, 1)

replace('''            let stage = ["accept-resume", "accept-after-visibility"].contains(requestedStage) ? "accept" :
                (requestedStage == "observe-replacement-resumed" ? "observe-replacement" :
                 (requestedStage == "observe-deletion-resumed" ? "observe-deletion" : requestedStage))''',
'''            let stage = requestedStage == "seed-and-invite" ? "seed" :
                (requestedStage == "recover-initial" ? "accept" :
                 (requestedStage == "recover-replacement" ? "export-replacement" :
                  (["accept-resume", "accept-after-visibility"].contains(requestedStage) ? "accept" :
                   (requestedStage == "observe-replacement-resumed" ? "observe-replacement" :
                    (requestedStage == "observe-deletion-resumed" ? "observe-deletion" : requestedStage)))))''')
replace('            let db = try await GraphDatabase.openMirrored(',
'''            let freshReplica = ["recover-initial", "recover-replacement"].contains(requestedStage)
            let storeRoot = freshReplica ? root.appendingPathComponent(requestedStage + "-replica") : root
            if freshReplica {
                guard !FileManager.default.fileExists(atPath: storeRoot.path) else { throw Failure.replay }
                try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
                log("New replica directory allocated without copying a native store.")
            }
            let db = try await GraphDatabase.openMirrored(''')
replace('privateStoreAt: root.appendingPathComponent("private.sqlite"), sharedStoreAt: root.appendingPathComponent("shared.sqlite")',
        'privateStoreAt: storeRoot.appendingPathComponent("private.sqlite"), sharedStoreAt: storeRoot.appendingPathComponent("shared.sqlite")')
replace('            if stage == "identity" {',
'''            if stage == "prepare-owner" {
                log("Native resources ready for the pinned recipient transport; no fixture seeded.")
            } else if stage == "identity" {''')
replace('                try await a.close(); try await b.close()',
'''                if requestedStage == "seed-and-invite" {
                    let recipient = try read(GraphSharingIdentity.self, at: identityURL, run: run)
                    try write(try await db.invite(recipient, to: a.id), at: invitationURL, run: run)
                    log("Pinned participant invited by the original retained seed owner.")
                }
                try await a.close(); try await b.close()''')
replace('let export = root.appendingPathComponent(stage == "accept" ? "exported-large.bin" : "exported-replacement.bin")',
        'let export = root.appendingPathComponent(freshReplica ? requestedStage + "-export.bin" : (stage == "accept" ? "exported-large.bin" : "exported-replacement.bin"))')
if '@testable' in text or 'schema: .nativeIdentity' not in text:
    raise RuntimeError('S01 host must consume the explicit public schema API.')
probe.write_text(text)
