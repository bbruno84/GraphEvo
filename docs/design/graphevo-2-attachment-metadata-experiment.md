# C03a — split attachment metadata, first local experiment

Status: isolated experiment on `codex/v2-attachment-metadata-experiment`, based on
C02a preferred B (`e2e53ab5743b117e74ffc52ea9d9ab133b8818bb`). Not integrated,
not a final schema decision and not complete C03 acceptance.

## Hypothesis and scope

Separating descriptive metadata from original bytes should make file listing
independent of body size. Keep attachment identity/exclusive owner, graph/share
membership, native model, Core Data synchronization, content limit, complete-read
checksum validation, query budgets and conservative observer behavior unchanged.
Change one access path first; do not simultaneously redesign query evaluation.

New imports keep the same attachment Entity and use two ordinary native detail
properties. `attachmentMetadata` holds a binary plist envelope version 2 with
metadata, while `content` holds original bytes. Both still use GraphValueCodec;
this experiment does not remove JSON/Base64 overhead on full reads. The existing
A5 insertion plan includes both values in native assignment and durable intent.
A local replacement updates existing values atomically under revision checks;
CloudKit import is not atomic across independently mirrored values. Complete
reads reject mixed metadata/body checksums. Listing certifies neither body
availability nor checksum; no progress/download-state API is introduced.

The listing adapter inventories/checks identities and membership as before, then
reads only the metadata key through the scoped facade. It checks the encoded-key
list and does not decode unrelated user values. Legacy envelopes fall back to
complete verified decoding. Results keep stable ID ordering and owner filtering.
Queries deliberately still snapshot every scoped record, including file bodies,
and charge their actual encoded bytes before decoding. Default-budget refusal
for four large files must remain in this first experiment.

## Existing data and boundaries

Read/list/export/deletion support existing A6 envelopes without modifying them.
Their replacements retain the old one-property representation, so native shared
replacement needs no additional assignment. New split values are unsupported by
older A6 readers. There is no migration on open and no loss of old bytes/IDs;
coordinated conversion remains a documented gate. Unknown properties, tags,
creation date and graph links remain unchanged by ordinary replacements.

The candidate adds no direct CloudKit records, assets, sidecar content files,
selective download, managed-object escape or cross-operation cache. Two-value
participant insertion, replacement, remote conflict and partial-import recovery
must receive dedicated physical-device acceptance before adoption. Local plan
round-trips and model hashes do not establish those outcomes.

## Measurement and checks

Use unchanged C01 Release executable/runner fixtures, budgets and assertions,
three repetitions per non-seed operation. Compare immutable copied B and candidate
executables in new external directories; no build/tests during timed matrices.
Retain timings, actual encoded byte charges, process RSS samples, directory sizes
and limitations. Baseline and candidate seed their own format; this is not a
conversion benchmark. Test mixed legacy/split reopening and replacement separately.

Regression coverage must retain original attachment/owner/edge cascade, rollback,
backup/reopen, source cancellation, size limits and full sharing validation. Add
split metadata/body mismatch, malformed/future metadata, mixed representation,
unknown-property preservation and a poisoned body that listing must not decode
while complete reads and sharing integrity still fail. Run the full suite and
required manifest/diff checks. Publish results before choosing the next change.
