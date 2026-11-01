# MF04c — bounded workspace sealing and explicit recovery

Date: 2026-11-01. Base: integrated MF04b/#124 (`7c2b5a9`). Focused branch:
`codex/v2-workspace-seal-recovery`, directly targeting `codex/graphevo-2`.
This groups sealing, PH reduction, explicit restart/source freshness and cleanup
activation ownership into one functional increment. It is not publication evidence.

## Delivered behavior

A reserved root marker commits with full structural/file validation and PH
reduction in one exclusive workspace transaction. The bounded manifest contains
logical ID/kind/final operation and range provenance, never file bodies. Repeated
seal is stable; before-save cancellation rolls back and after-save cancellation
reports committed success. A durable marker row still fences mutation if its
value is missing/corrupt. No source checkpoint, transport queue or consumer body
is replayed. Insert-then-delete identities are excluded without a semantic diff.

Explicit reopen validates immutable format-2 descriptors, physical/native
source/working identity, retained baseline author/token and source PH before
returning editable or sealed access. It accepts bookkeeping only if reconstruction
shows no application effects. It restores the native seal without a separate JSON
commit. Same-volume moves retain identity; replacement/cross-volume copies and old
alpha workspaces are refused unchanged. Participant workspaces remain disabled.
Every activation rotates cleanup authority; stale controls cannot delete a reopened
copy, even after its new owner closes. Cleanup retains native/registry/global claims
through detachment and owned deletion, including retryable preflight failures.

No Core Data S03, application cloud format or session format change; workspace
format 2 deliberately refuses format 1. No backup, ledger operation or cloud/data
publication is created. Portable backup import and protected source publication
remain distinct work.

## Local validation

Environment: Xcode 27.2 / Swift 6.4.2, macOS 27.0.1; iOS Simulator 18.5.

- Complete macOS package: 859 functions passed on `a1334e2` (331 legacy XCTest;
  429 store, 76 runtime, 23 model Swift Testing functions).
- Complete selected iOS store/runtime/model: 527 functions / 623 invocations passed
  on that same source pin; no failures or skips.
- Review then corrected privileged writer accounting and marker-row admission,
  adding one native corruption regression. Final focused macOS: 32 workspace
  functions plus 17 runtime transaction functions passed. Final focused iOS: 49 functions / 60 invocations passed, no failures or skips.
- `swift package dump-package` and `git diff --check` passed.

The 21 sealing/recovery test functions (30 parameterized invocations) cover no-op
and repeated seals, restored original values, transient insert/delete, all primitive
kinds, 2-MiB files, empty/repopulate, cascades and surviving actions, detail/tag/group
removal, rollback, all explicit limits, missing/pruned/unknown/import history,
source changes and bookkeeping-only progress, metadata-authored application changes,
replaced/corrupt inputs, moved paths, stale activations, aliases, admitted writers,
coalesced seal, cancellation before/after commit, native commit without in-memory
result, and retained detached cleanup claims. Ordinary sources cannot use privileged
workspace commit/deletion routes. A missing native marker value still blocks writes
and recovery. Existing preparation, backup, transport and conflict suites retain
coverage of the shared PH processor and original preservation.

## Independent-process local protocol

Source pin: `a1334e21f95f4b0f945898f16804b45206eea333`. The disposable local fixture
and additional test source live outside the repository; they are not CI inputs.
Each stage reserves a new `.started` marker and is not replayed.

1. Process 82931 creates the original with two entities and a 2-MiB attachment,
   prepares/empties the working graph and creates a new entity plus file. It commits
   the native seal directly before installing any runtime seal result. An injected
   before-detach failure causes close to retain the copy/native claims; source
   writes remain suspended. Objects remain retained until the process exits.
2. Process 83481 registers current source URLs and explicitly reopens the workspace.
   It recovers exactly the committed manifest: three baseline deletes and two final
   saves. It verifies both complete files, original tags/content, write refusal on
   the sealed copy and successful owned cleanup. Source PH discovers only its three
   original records, then four after an independent post-recovery local insert.
   Working changes did not feed the source queue. No backup was created.

Both stages passed with different process IDs. This proves the bounded local
protocol after injected pre-detach failure and process replacement; it does not
certify hardware I/O failure or power-loss durability. Subsequent review changes
writer accounting and corrupt-marker refusal, with focused tests; the process
protocol is not relabeled as a run of those later corrections.

## Remaining acceptance

Original-store publication/backup/commit-marker recovery, actual CloudKit migration
publication, participant permissions/revocation, power-loss/incomplete-stage cleanup,
external-process writers, hostile filesystem races, cross-volume/device workspace
adoption and production scale remain open. Tokens/native seal metadata and full
validation/copy costs stay on the post-alpha checklist. No beta/stable gate or
release/tag closes here. CI is requested only after review on the final code.
