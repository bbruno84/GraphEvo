# V01 — incremental owner-only membership and fresh same-iPad recovery

Status: relationship/save-only addition, edit, deletion, reopening and new cloud
replicas were observed on the same physical iPad. The independent same-account
peer was disconnected, so that part of the originally proposed test remains open.
This follows the [initial zone recovery](v01-t6-independent-reader-2026-10-24.md)
and closes only the stated parts of [V01.4–V01.7](../graphevo-2-test-checklist.md).

## Fixture and supported operation under test

Run `66DD1A44-6C01-4C5F-BB78-EE644BC3BF22` used a new private SQLite and the
experimental root/child model. A-root owned A-001/alpha and A-002/beta; B-root
owned B-001/gamma. Two initial owner-only shares had public permission `.none`:

| Graph | Pinned zone |
|---|---|
| A | `com.apple.coredata.cloudkit.share.2BC84FF2-25A8-495C-B4DF-42D9D1261682` |
| B | `com.apple.coredata.cloudkit.share.02BFA1CF-6882-4815-87D5-EA275DC93C7E` |

The writer was then reopened at its original SQLite path. It inserted
A-003/delta, related it to the existing A-root, updated A-001 to
`alpha-updated`, and saved once. It did **not** call a sharing API for A-003 or
replace/recreate either share. The new node acquired A's existing share and
zone, and all original record/share identities remained stable. A fresh private
SQLite recovered all six exact DTOs from cloud with no seeding or file restore.

The original writer next deleted A-003 and saved once. A-root's inverse children
returned to A-001/A-002; A-001 retained its updated value. The writer reopened
successfully, and another fresh private SQLite recovered the exact five-member
state from cloud. B's complete DTOs, including values, links, permissions and
identities, remained identical throughout. Three different fresh reader stores
matched the writer's original, added and deleted phases respectively.

There were exactly two initial share-creation calls and zero existing-share
extension calls in all stages. One initial fixture save, one addition/edit save
and one deletion save were retained. A ledger reserved mutations before native
writes and prevented automatic replay. Readers queried the entire run, opened
new store identifiers, and copied/restored no SQLite files. The ledger supplied
expected comparison values but did not seed the reader's Core Data store.

## Initial metadata preflight and focused correction

The first add-stage attempt ended at 07:11:39 UTC **before mutation**. All five
rows, values, links and cloud record mappings matched the baseline, but every
`fetchShares` mapping was initially absent just after reopening. The immediate
precondition reported `GraphEvoDemo.V02Error:5` (invalid fixture). Retained ledger
state remained `ready`, with empty added/deleted snapshots, and the report
recorded `localMutationSaved = false`. This is not an observed failure of native
incremental membership or evidence that the shares were deleted.

The harness was corrected to sample read-only snapshots for complete pinned
prior-phase metadata before reserving a mutation. The report preserves both the
opening snapshot and final precondition. Tests cover initial missing mappings
followed by readiness, and timeout with zero mutations/unchanged ledger. The
post-save sampling window remains separate. The subsequent add was the first
actual add write, not a replay or fallback. Failed preflight JSON SHA256:
`b5a9e9547e71bdca52cd221e56f8fb3495ad4aa5674d00579dc87be8f149521e`.

The first external collection script also shadowed its expected phase name with
a display string. It copied the completed successful initial writer report but
failed to recognize the filename and reached its collection deadline (exit 3).
The retained native final report was verified before explicit process termination;
the collector variable was corrected for later stages. No native stage was
interrupted or replayed. This local collection issue remains recorded separately.

## Provenance and completed reports

Hardware: iPadOS 27.0 (24A437), one physical iPad and one owner account.
Xcode 27.1 (27A9275), Swift 6.4 (`swiftlang-6.4.0.34.1`) in Swift 5 language mode,
GraphEvo dependency `4dc0a7f9a717ee535e9b630b998cd6c869a2d538`.
Signed Development entitlements, runtime test destination, source metadata and
provisioning were verified for both builds. No Production resource was used.

Initial preparation/original reader and failed unstarted preflight used demo
`36f2ce5`, app Swift SHA256
`276f17592af290c0e2eeaa3aa50baa34f63c8a2ba60de2b45857f5c227e69df0`,
with 64 passing app tests. Successful addition and subsequent stages used the
read-only-preflight fix `0522aca`, SHA256
`e9624c218c928cf1b83305e5d32b39de5dbef4e218524defef6753ba1d9b2335`,
with 66 passing app tests. The model and native mutation calls were unchanged.
These app source hashes exclude standalone experiment packages and documentation.

All intervals below are UTC on 2026-10-26:

| Stage | Interval UTC | Members | Final JSON SHA256 |
|---|---|---|---|
| writer-prepare-original | 07:07:16–07:08:01 | 5 | `32d84d156952b3954e0b808a8b748345c07eba114c91f110d224ddd0b39bbee4` |
| reader-original | 07:11:11–07:11:16 | 5 | `e4cf91d771129be3f2175d65abaf8f62afab01859c94d45fc430b6f390e8a44b` |
| writer-add-added | 07:19:57–07:21:02 | 6 | `1aad986b73c87809da99d3d2797c55dfed478d90a944dcca79dd590def0de4ac` |
| reader-added | 07:22:15–07:22:20 | 6 | `205162c2c3431dc893ce79519d3e42179ba928c2bca0a27a012ba9fcf69efe36` |
| writer-delete-deleted | 07:22:38–07:23:43 | 5 | `dea8dfbfa7d2f6d9203c521574505cd37f75071873c621f0089a3639ddf82799` |
| writer-reopen-deleted | 07:24:24–07:24:27 | 5 | `7b272d3469cb2da228caf9d4bcc2f268b5a437311d04ea6cace656b25b556eae` |
| reader-deleted | 07:24:35–07:24:40 | 5 | `d64f9420ef5186e035960d9735ee4cbf7119a780fe249bc582aa9f9afd94c3a7` |

All seven completed successful reports retained exact fixture/preserved-identity
checks, no stage errors, no completed native event failures and no trace/event
drops or trace-write failures. Independent comparison outside the app matched
full DTOs between each writer/reader phase and pinned B/surviving A identities.
All native processes were explicitly terminated only after retaining reports.

The local GraphEvoLab archive
`2026-10-26-V01-membership-66DD1A44-6C01-4C5F-BB78-EE644BC3BF22` retains both
signed-build manifests, logs, failed preflight, ledger proof, completed reports,
traces, collection note and independent comparison summary. No wipe, purge,
app removal, source-store copy or cleanup of earlier experiment data occurred.

## Limits

This establishes automatic incremental membership and a complete 5→6→5 cloud
recovery sequence under these same-iPad conditions. A fresh cloud store is
stronger evidence than reading the writer's cache, but it does not substitute
for the disconnected independent same-account iPhone. No XR account was treated
as that owner-only peer. Cross-account incremental members, complex graph
facades, live imports into an already-open peer, selective download, scale and
other OS versions remain separate checks. The initial missing-share snapshot
also reinforces that local metadata lookup is not a synchronization barrier.
