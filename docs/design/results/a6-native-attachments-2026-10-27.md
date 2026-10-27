# A6 — native attachment lifecycle on the candidate GraphEvo model

Date: 2026-10-27. Status: positive for the scenarios below. Read the
[A6 contract](../graphevo-2-attachments.md) and
[probe procedure](../../../Experiments/A6NativeProbe/README.md).

## Environment and evidence boundary

Authorized synthetic Development container: `iCloud.com.valerioburiani.GraphCKDemo`.
The owner used the iPad on iPadOS 27.0; the participant used the iPhone XR on
18.7.10 with a different account. Builds used Xcode 27.1 / Swift 6.4. The demo
was prepared in a disposable directory, retaining the original checkout and
its local signing/configuration. All stages consumed public GraphEvo APIs.

Run `291F43CA-76F3-4B93-B780-B6CFC8DD5F7D` used one native private/shared owner
per process and unique one-use stage reports. Native owners remained retained
through independent observation. No reserved stage was replayed; no account,
container schema or existing fixture was reset. Only protected, run-bound
fixture/recipient/invitation envelopes were transported. Their payloads, native
logs and stores remain outside Git.

Source evolved before the A6 commit. Initial setup/import stages preceded the
final integrity and exclusive-file-publication hardening. Subsequent clean
builds updated the participant before a separate replacement-export check and
the owner before cascade checks. This is working-source evidence, not a claim
that every stage ran one immutable commit. Native model hashes stayed unchanged.
The final read-only boundary ticket additionally tightened an earlier optional
B-share comparison: both share boundaries must be non-nil before comparing
them. It observed both present and distinct without repeating a mutation.
An initial Xcode invocation emitted a diagnostic about a command exiting zero
without output; subsequent device builds completed cleanly and installed apps
ran successfully. There were no failed or replayed runtime stages in this run.

## Independent observations

A and B each had a distinct native sharing boundary. A started with one owner,
a 512-byte file and a 10,485,760-byte file. B had its own owner and 512-byte
control file. A alone received a private invitation to the pinned participant.

| Stage | Observation |
|---|---|
| Owner seed / participant identity | Actual GraphEvo attachment API prepared the complete fixtures and protected account-bound transport. |
| Invite / accept | Participant recovered A's exact original bytes, complete metadata and SHA-256 values; B was absent. All selected native node/detail mappings were present in A's boundary. Independent export of the 10-MiB file was byte-exact. |
| Participant add / owner observe-add | Participant imported another 512-byte file with the existing A owner through A5's explicit native assignment. Owner independently recovered its pinned ID, bytes and metadata, while B stayed unchanged. No pending-assignment recovery was needed in this stage. |
| Participant replace / owner observe-replacement | Participant replaced the large file with different exact bytes and filename, preserving file/owner IDs and changing revision. Owner independently recovered the new bytes/checksum, filename and revision change, the remaining files and unchanged B. |
| Participant export-replacement | A separate process launch with the hardened exclusive-publication implementation exported the replacement's exact 10-MiB bytes. |
| Participant delete / owner observe-deletion | Owner independently observed only the large attachment disappear; A's small original file, participant-added file and B control retained their values. |
| Owner cascade / participant observe-cascade | Deleting A's owner removed its remaining owned files locally. Participant independently observed the owner and all three attachment IDs absent; B remained absent on its account. |
| Owner final / final-boundary | Separate owner launches verified the A owner/attachment IDs absent, B's exact original control content/metadata retained, and both non-nil boundaries distinct with no pending/mismatched mappings. |

Checks used pinned graph/node identities, bytes/counts, checksums, graph membership
and public native mappings for every selected owned row. Original/control metadata
was compared in full; replacement checks pinned IDs/owner/count/checksum and
verified filename/revision change. No physical external-storage placement was
inspected or inferred. The payload is stored through the current transformable
property with external storage permitted, not V09's surrogate binary model.

## Sampled process memory

Resident bytes were sampled every 20 ms during each stage, including native
setup and framework costs. Values below are MiB, rounded to one decimal.
They are process samples, not an absolute transient maximum or attribution of
all memory to attachment bytes. Synthetic files contained repeated bytes, so
these windows do not establish arbitrary-content performance.

| Device / stage | Baseline | Sampled peak | Delta |
|---|---:|---:|---:|
| iPad seed | 27.0 | 132.4 | 105.4 |
| XR accept and original export | 19.9 | 93.4 | 73.5 |
| XR shared import | 19.6 | 127.6 | 108.0 |
| XR 10-MiB replacement | 19.6 | 187.1 | 167.5 |
| XR replacement export | 19.8 | 153.3 | 133.5 |
| iPad final control | 27.4 | 49.8 | 22.4 |

The alpha accepts empty files through 10 MiB per attachment and buffers complete
content/encodings. This is a chosen library envelope, not an Apple limit or a
whole-store memory bound. Metadata listing currently decodes complete content.

## Local validation and remaining gates

The full local macOS suite passed 439 tests: 322 legacy, 56 runtime, 42 store
and 19 model. Attachment tests cover source removal, empty/10-MiB copy/reopen,
replacement, exact export, oversized/invalid input, cancellation before mutation,
owner deletion for all three node kinds, implicit-edge ownership, rollback,
metadata/owner tampering, missing-owner sharing integrity and complete closed
local-directory backup/reopen. Exclusive publication rejects existing files and
dangling links. The independent Swift 6 consumer exercises import/read and owner
cleanup. Manifest, Release and diff checks passed. Targeted Thread Sanitizer
passed eight store attachment tests and one model payload test without a
reported race. Pre-existing legacy warnings remain outside this increment.

Closed-directory copying/reopening is local SQLite evidence; restoring a mirrored
private/shared group against cloud data is not validated here and is not a cloud
rollback protocol. Existing migration callers still need whole-content source
backup and coordinated cutover work. Ordinary v1 binary properties are preserved
as such rather than automatically converted into attachments.

Still open before release: real document-provider/security-scope variants,
physical offline/account-cache policy, conflicting remote replacements,
owner disappearance during native assignment and reconciliation/abandonment of
retained partial intent, larger/representative datasets and the broader supported
OS matrix. The strict missing-owner fixture is local injected evidence, not a
new cross-device failure test. A5's separate process-interruption result does
not establish every A6 file-interruption combination. No streaming, per-file
progress, selective download, eviction or global synchronized state is claimed.
