#!/usr/bin/env python3
"""Reuse the one-use A6 lifecycle in a disposable demo, adding split-format assertions."""
import argparse
from pathlib import Path
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("demo", type=Path)
parser.add_argument("destination", type=Path)
args = parser.parse_args()
subprocess.run([sys.executable, str(Path(__file__).resolve().parent.parent / "A6NativeProbe/prepare_demo.py"),
                str(args.demo), str(args.destination)], check=True)
source = args.destination / "GraphEvoDemo/A6NativeProbe.swift"
text = source.read_text()
needle = "                try await graph.close()\n                let mapping = try await db.inspectMirroring(for: fixture.a)"
assert text.count(needle) == 1, "Inspect upstream A6 verification before generating the matrix probe."
text = text.replace(needle, '''                var expected = [fixture.small.id]
                if !deletion { expected.append(fixture.large.id) }
                if let addition { expected.append(addition.id) }
                let expectedIDs = expected
                try await graph.read { scope in
                    for id in expectedIDs {
                        guard let record = try scope.record(for: id),
                              case .data = record.properties["attachmentMetadata"],
                              case .data = record.properties["content"] else { throw Failure.fixture }
                    }
                }
                try await graph.close()
                let mapping = try await db.inspectMirroring(for: fixture.a)''', 1)
source.write_text(text)
