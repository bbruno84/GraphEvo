# MF11 — native staged v1 conversion

Status: integrates through [PR #141](https://github.com/bbruno84/GraphEvo/pull/141),
2026-11-02. Reviewed full checkpoint #381 passes on both platforms; public,
production, historical-source and cloud acceptance retain their separate gates.

Use Core Data staged migration for the known v1-to-S04 physical transition and
library-owned custom handlers for identities and property conversion. The original
stopped source stays read-only. A verified, pinned backup seeds a separate,
exclusively owned workspace at the requested destination. Ordinary opening refuses
that workspace until the complete graph and conversion receipt are committed.
No CloudKit work is started.

Unlike the retained bounded MF07 recipe, this path does not collect all records
or charge a whole-database payload allowance. Source fingerprints are streamed
one record at a time; native handlers save bounded row batches and refault their
contexts. One individual legacy value must still fit the platform decoder's
working memory. This is not a total memory/time or disk-space guarantee. Existing
format-1 identity-map/receipt and native-history bounds remain explicit alpha
format constraints, separate from total property bytes.

A normal v1 container retains legacy lookup IDs and allocated UUIDs in the
isolated copy before Core Data starts the schema hop. Its native stores detach
without releasing the runtime gateway claims. This avoids relying on migration
callback contexts to retain newly inserted identity-detail rows under concurrent
schema migrations. Core Data performs the additive schema change. The did handler
moves each user property into its S04 typed slot and stamps native identities.
Completed typed slots and node projections are durable checkpoints; the same
idempotent transformation also runs after load, because a restart can already
have the target physical model without having completed its did handler.

Final sealing creates catalog/membership links and validates all converted data
against the original semantic fingerprint. This unpublished catalog is saved
while workspace admission remains closed. Its target-history cut establishes a
fresh sync epoch and explicit pending saves for every converted application node;
no source cloud checkpoint is copied. A final metadata transaction writes that
baseline and the existing conversion receipt and removes workspace admission.
Core Data metadata updates are persisted by that native save, not by merely
changing the coordinator's in-memory dictionary. Cleanup failure retains native
ownership. A committed receipt remains authoritative after cancellation or an
opening failure. Later v2 edits are never replayed over by recovery.

Stable GraphID/operation ID/current URLs remain caller supplied. Source and old
writers must be stopped; no distributed fence or completeness certificate is
inferred. The historical MF07/MF09 APIs and formats remain available. Public
bootstrap, other source models, larger identity-map formats, cross-process writer
coordination, cloud cutover and beta acceptance retain their separate gates.

## Package entry and native ownership

`openGraph(convertingLocalV1:)` selects this route with the production factory on
iOS 17/macOS 14 or later. `openGraph(migratingNativeV1:)` selects it explicitly.
The overload accepting `GraphV1ConversionLimits` and `convertLocalV1Store` retain
the historical bounded atomic recipe. Existing complete receipts recover without
reapplication. Uncommitted bounded-recipe files still require their original
explicit bounded recovery path; they are not silently reinterpreted as native
workspaces. The default public v1 Graph initializer is unchanged.

Target seeding prepares a temporary native copy and writes its workspace/document
metadata before publishing it at the requested destination with Core Data's
whole-store replacement API. A metadata-write failure leaves that destination
absent and retryable, rather than exposing an unmarked v1 copy. The original
restored input stays unchanged. Temporary copies are removed after closed native
operations; abrupt process termination can leave an unused temporary directory.
This extra native copy has disk/I/O costs and does not certify every physical
interruption boundary.

The runtime's optional native initializer requires an exclusive writable local
workspace/session. Canonical aliases include that admission and its immutable
native document. Source preparation and target load run under one pending owner;
only one native container has attached stores at a time. Load, preparation,
handler or seal failure detaches all loaded stores or retains the existing
initialization quarantine. No callback context/container escapes the operation.
The normal legacy compatibility check refuses isolated workspaces as well.

The path-local `GraphEvo.nativeV1Migration` format-1 document binds the existing
intent to its allocated UUID map. It contains no sandbox URLs. S04, primitive,
asset, session, backup and completed conversion-receipt formats are unchanged.
Core Data can preserve the source native store UUID during schema evolution;
that is separate from new graph/node logical UUIDs and physical resource
ownership. The immutable original and backed-up source are never relabelled.

After native initialization is admitted, caller cancellation drains that owned
native work through its real outcome. A successful seal returns conversion proof
and a separate cancelled opening result. Earlier cancellation refuses admission.
Checkpoint/decoder/native failures retain their actual cause; there is no arbitrary
consumer-body replay. Other graph operations keep progressing independently.

The source inspection refaults each record after hashing, but identity inventories
are retained as bounded metadata. Stage handlers process 128 native rows per save
and release their contexts' cached payloads between batches. Already active typed
slots are not rewritten on recovery. A whole record/individual legacy value and
Core Data's own migration work still have platform memory requirements.
The retained format-1 map allows at most 10,000 application records/3 MiB map,
4 MiB receipt and 100,000 source rows with the normal PH preview bound. These are
explicit alpha format/metadata constraints; no total property-byte ceiling is
used by this native path. Larger identity formats remain separate work.

Verified source backups remain pinned until a successful receipt. The generated
`.graphevo-native-v1-<operation>` input directory is retained beside the destination
for deterministic recovery; it is not an extra backup-list entry. No private
fixtures or generated stores enter Git, CI, devices or CloudKit.

Apple references: [staged migration](https://developer.apple.com/documentation/coredata/nsstagedmigrationmanager),
[custom stages](https://developer.apple.com/documentation/coredata/nscustommigrationstage),
[metadata persistence](https://developer.apple.com/documentation/coredata/nspersistentstorecoordinator/setmetadata(_:for:)).

Validation: [MF11 bounded local evidence](results/native-v1-staged-migration-2026-11-02.md).
