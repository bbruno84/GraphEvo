# S06/S07 physical capacity and cost — 2026-11-08

Baseline: integrated `30c01ab6` from #191. The signed disposable host uses Release,
iOS 17 minimum, with shipping sources byte-identical to that baseline. The only
additional code is the external laboratory probe and its synthetic transport
helper. No production implementation, schema, admission limit or budget changes.

Physical devices: 10th-generation iPad, iPadOS 27.0 (24A437), and iPhone XR,
iOS 18.7.11 (22H384). All measured phase endpoints report nominal thermal state.
The two devices differ in both hardware and OS; this is not an isolated CPU or
OS comparison. Caches, power and storage state are not experimentally controlled.

## Protocol and scope

Twelve accepted fresh-process trials pass, with **108 measured phases**:

- Two fresh 25.92 MB string publication/recovery trials per device.
- One attachment/File trial per device; read phases repeat three times in-process.
- Two fresh representative MyHomeBills conversions per device.
- One paired unrelated-attachment deletion control per device.

Every run has a new UUID, SQLite paths and actual-process/active-scene launch
receipt. No consumed mutation is replayed. Successful stages close all stores
and synthetic sessions before reporting. A first iPad binary trial is retained
separately as harness evidence; its File checksum helper retained autoreleased
read buffers and it lacked the admitted full-query comparison. Final binary
results use the corrected bounded helper on both devices.

These are **local physical-device costs**, not new real CloudKit transfer
measurements. The string test executes activation, spool, receipts and independent
empty-store recovery against a deterministic in-process service. Existing real
CloudKit iPad/XR evidence in the [contract acceptance](property-attachment-contract-2026-11-08.md)
retains its original scope. There are no new network upload, sharing or bandwidth
claims in this run.

## Strings: initial publication and independent recovery

The fixture has 36 strings of 720,000 UTF-8 bytes and a small converted legacy
source. Both devices execute the same fixture and service. Its small source is
not identical to the macOS unit fixture; do not infer an exact cross-host speed
ratio from total test durations. All four trials require exact recovered values,
zero outgoing replica work and unchanged synthetic send count during recovery.
Every trial performs 38 activation advances and 37 sends.

| Phase | iPad, two fresh runs | XR, two fresh runs |
|---|---:|---:|
| Prepare | 0.55 / 0.55 s | 2.53 / 2.63 s |
| Synthetic publication | 9.89 / 9.68 s | 23.86 / 24.38 s |
| Import into empty replica | 4.17 / 4.16 s | 11.45 / 11.55 s |
| Verify 36 values | 0.17 / 0.18 s | 0.32 / 0.32 s |

The corrected local path completes on both devices. Two repetitions establish
bounded repeatability, not a percentile or a supported latency SLA.

## Attachment and File envelope

Each graph contains 32 keyed attachments of exactly 2 MiB, totaling 64 MiB.
Insertion, reopen, byte-exact bounded reads and replacement pass. A replacement
at 2 MiB + 1 byte is refused before its accompanying scalar patch changes state.
Count and selected-property projection succeed at a 4 KiB property allowance;
full materialization at that allowance fails. A separate admitted 96 MiB query
returns all 32 records and verifies every 2 MiB body.

| Operation | iPad | XR |
|---|---:|---:|
| Insert 32 × 2 MiB, one transaction | 0.515 s | 0.415 s |
| Count, median of three warm reads | 4.52 ms | 7.23 ms |
| Scalar projection, median of three | 10.03 ms | 16.30 ms |
| Metadata for 32 owners, separate per-owner calls | 436.62 ms | 652.14 ms |
| Read/compare all bodies, one owner at a time, median | 204.24 ms | 322.00 ms |
| Materialize all 64 MiB in one admitted query | 89 ms | 138 ms |
| Import 128 MiB File | 482 ms | 622 ms |
| Replace 128 MiB File | 268 ms | 576 ms |
| Hash 128 MiB through scoped URL, median of three | 79 ms | 104 ms |

The File trial also imports, hashes, replaces, deletes and reclaims 25 MiB.
The checksum helper reads 1 MiB at a time and drains its local autorelease pool.
Source generation and Mac/device transfer are outside timing. Repeated hashes
can benefit from the OS page cache; this is not raw-storage bandwidth.

Memory is sampled physical footprint every 25 ms, plus boundaries, including
the host/frameworks; it is not an instantaneous peak or an allocation trace.
The admitted full query samples 134.1 MiB on iPad and 72.9 MiB on XR. Reading
owners separately samples at most 14.4 / 10.5 MiB respectively. The 128 MiB File
import samples 12.4 / 8.3 MiB, and pooled checksum reads 12.4 / 8.4 MiB. These
observed process footprints support the distinction between retained Data
results and scoped File access; they do not certify a constant-memory API or
establish a maximum safe file/graph size. Very short allocations may be missed.

## Representative MyHomeBills store

Each trial receives a complete fresh copy of the stopped SQLite/WAL/SHM source.
The original archive and extracted Mac artifacts stay external and unchanged;
device trials also compare the source artifact digests before/after conversion.
The existing native conversion owns schema changes, backups and canonical
fingerprint verification. No application content is interpreted or rewritten.

All four conversions yield the same inventory:

- **1,577** mapped source nodes, with **4,943** supported properties.
- **244** extracted keyed attachments totaling **109,100,230 bytes**.
- Largest attachment: **489,900 bytes**, below ordinary 2 MiB admission.

| Operation | iPad, two fresh runs | XR, two fresh runs |
|---|---:|---:|
| Native conversion including backup | 36.30 / 37.34 s | 84.66 / 85.31 s |
| Materialize every source owner separately | 9.83 / 9.69 s | 17.20 / 17.15 s |
| Full integrity validation | 0.99 / 0.99 s | 1.82 / 1.83 s |
| Reopen | 1.06 / 1.07 s | 1.92 / 1.92 s |
| One global metadata listing | 0.24 / 0.24 s | 0.36 / 0.36 s |

Conversion samples a maximum 111.4 MiB footprint on iPad and 149.5 MiB on XR.
The owner-at-a-time read samples 13.5 / 9.4 MiB; full validation samples 22.0 /
109.0 MiB. These stages have different materialization/lifetime behavior; the
source's overall binary size is not a per-read allocation requirement. The
conversion measurement includes backup and multiple validation/native phases;
no breakdown or universal migration deadline is inferred from this total.

This source does not require a File conversion to stay below the ordinary
attachment threshold. That fact does not classify its attachments as images,
UI icons or documents. Any consumer-owned conversion to File needs an explicit
semantic mapping; none was attempted.

## Confirmed remaining problem: unrelated content during deletion

An empty File is deleted from two fresh reopened stores: one with no attachments,
the other with 32 unrelated 2 MiB attachments. The unrelated owners survive.

| Empty File deletion | iPad | XR |
|---|---:|---:|
| No unrelated attachments | 10 ms | 14 ms |
| 64 MiB unrelated attachments | 111 ms | 152 ms |

`GraphTypedStoreAdapter.Session.deletionPlan` currently builds its owner map by
calling a complete attachment snapshot for every attachment. That reads and
validates unrelated bodies although metadata already identifies ownership. The
control corroborates this extra work; it does not establish an exact linear
cost or an I/O byte counter. Sampled footprint changes differ between devices
(11.1 to 43.3 MiB on iPad, 7.9 to 10.1 MiB on XR), so a universal memory-growth
claim is not warranted.

This is a **confirmed optimization task**, separate from missing acceptance
coverage. Preserve metadata/identity, cascade, permissions and pre-edit checks
when changing the deletion plan, and validate affected content rather than
silently skipping integrity. No runtime correction is included in this lab.
Per-owner repeated metadata queries also cost more than one global listing;
these are different workloads and this result alone does not select an API change.

## Remaining acceptance and reproduction

The maintainer accepts the selected thresholds/limits block as **closed for
alpha**, integrating evidence through #192. The deletion optimization and wider
physical/source/network verification remain beta backlog. Review of laboratory
implementation `15d5bb15` found no unresolved integration blocker; final closure
notes change documentation only. This acceptance changes no runtime or limit.

The selected physical functional cases pass. Broader PA05/PA06/PA08 remain open:
larger/mixed graphs, 50 GB physical File acceptance, jetsam and memory pressure,
provider storage, protected data, interrupted backup/conversion, wider source
formats, sustained workloads, distributed conflicts and actual network costs.
No maximum supported device envelope, alpha tag or beta acceptance is declared.

[DeviceCapacity](../../../Experiments/DeviceCapacity/README.md) retains the
source, host preparation and guarded runner. Raw metrics, receipts, fixtures,
source hashes, signing files and logs remain outside Git. Final collection is
validated against expected stage counts and preserves the initial harness trial.
Release build, both physical installations, Python syntax/preparation checks,
shipping-source comparison and `git diff --check` pass. No hosted CI is requested
for this experiment/documentation-only increment.
