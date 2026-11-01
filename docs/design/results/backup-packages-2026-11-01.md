# MF02 — `.geb` package results

Date: 2026-11-01. Candidate on `codex/v2-compressed-backups`, based directly on
#120 (`2009582`). Contract: [MF02](../graphevo-2-backup-packages.md).
Implementation pin: `3e509f0`. Later delivery/status edits are documentation-only.

## Functional evidence

Completed backups are single `.geb` files with a bounded readable manifest and
compressed native/artifact bytes. Native verification and attachment checks run
after decoding on an owned disposable copy. Graph-owned snapshot holds end after
coherent native copying, while compression/verification continue independently.

Committed tests cover compressed native/attachment/PH round-trip, reasons,
manifest-only discovery, byte-identical export after the live graph changes,
independent-manager collection import, duplicate and occupied destinations,
same-root export, legacy directory reads/export and durable retention.

Malformed inputs cover magic/version/codec/manifest corruption and lengths,
truncated files and streams, appended/concatenated streams, unsafe relative paths,
declared extraction limits and actual output exceeding declared file sizes. No
failed import/restore publishes a destination. Cancellation after the export copy
preserves the source, retention owner and graph write availability and removes
the owned stage. Earlier MF01 native corruption, pause composition, reserved
observation recovery and missing-content checks remain covered.

The initial Apple Compression decoder admitted trailing bytes even when the test
updated the container length correctly. Lookahead/finalize flags did not solve
that counterexample. SDK zlib's explicit input accounting now rejects it, and the
committed tests retain trailing, concatenated and truncated-stream regressions.
No source implementation of either compression library is copied or vendored.

## Local compression comparisons

Apple Silicon host, macOS 27.0.1, Xcode 27.2. The preliminary Foundation comparison
used two synthetic approximately 8 MiB in-memory inputs, Release optimization and
one sample per algorithm; it is not a production benchmark or a codec throughput
contract.

| Synthetic input | Algorithm | Source bytes | Compressed bytes | Seconds |
|---|---|---:|---:|---:|
| Repetitive metadata JSON | LZFSE | 8,388,693 | 5,204 | 0.021 |
| Repetitive metadata JSON | zlib | 8,388,693 | 28,571 | 0.021 |
| Deterministic incompressible bytes | LZFSE | 8,388,608 | 8,472,617 | 0.583 |
| Deterministic incompressible bytes | zlib | 8,388,608 | 8,391,163 | 0.133 |

The package implementation selects raw DEFLATE through SDK zlib, level 5, with
strict end/input consumption and bounded streaming buffers. The synthetic
comparison supports this compromise; it does not claim that photos compress well.

## Bidirectional native package transfer

A local-only probe created one fresh macOS fixture and one fresh iOS 18.5
Simulator fixture. Each contains one application entity and two 2 MiB attachments
(repeated bytes and deterministic incompressible bytes). Native copying includes
its actual companion resources; reported native bytes sum the manifest inventory.
Each writer exported one completed immutable package. A separate recipient
collection imported and restored it without the source manager/sandbox path.

| Writer | Native inventory bytes | `.geb` bytes | Snapshot/compress/verify seconds |
|---|---:|---:|---:|
| macOS | 8,852,712 | 4,260,035 | 0.136 |
| iOS Simulator | 8,844,496 | 4,260,414 | 0.201 |

Both **macOS → iOS Simulator** and **iOS Simulator → macOS** passed full native
reopen, expected application value, two complete attachment reads/checksums and
the three expected PH-derived pending primitives. The second macOS stage was
read-only recovery: it did not seed/replay the existing writer. This is offline
backup transport/restoration, not a fresh CloudKit replica or independent-user
graph activation test. No sync engine, account, physical device or container
reset was involved. Native stores/packages, probe source and logs remain local;
the probe is not a CI test or shipped API.

## Final checks and limits

Full local suites pass **785 macOS functions** (331 legacy, 355 store, 76 runtime,
23 model) and **430 selected iOS Simulator functions**, 507 invocations including
parameters, with no failures/skips or summary runtime warnings. Release package
build, Swift 6 ModelConsumer, package manifest and diff checks pass. A subsequent
focused destination regression extends direct/symlink checks to a case alias
when the volume exposes it; that does not change library source or function counts.
The final focused macOS function passes all three arguments; the final iOS backup
suite passes 14 functions/16 invocations. An earlier narrow Xcode method filter
matched zero tests and is excluded from the evidence; the suite filter above
supplies the actual final coverage.

No remote CI or merge is requested before review. File-provider/UI coordination,
power-loss durability, production memory/disk/media scale, physical transfer and
independent cross-user graph activation/reference remapping remain open. Import
into a backup collection and same-identity local restoration do not activate old
sharing/account/transport state or replace a live graph. Checksums provide
integrity checking, not provenance/authentication.
