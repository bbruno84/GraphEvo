# MF08 internal migration structure — 2026-11-01

Scope: factor MF07 into concrete typed transition definitions and shared
ContextManager execution. No new production schema, public opener, registry or
CloudKit activation. Source pin: `fdf22c3b727307f83b51e9421edecf635a4678e0`.
PR: [#130](https://github.com/bbruno84/GraphEvo/pull/130), directly into
`codex/graphevo-2` from integrated #129.

## Local checks and review

- Full macOS suite: 890 functions (331 legacy XCTest, 460 store, 76 runtime,
  23 model), all passed.
- iOS Simulator runtime/store/model: 558 functions, 664 expanded invocations,
  zero failures. This local run does not include the legacy iOS target.
- Final focused new-definition suite: four functions/seven invocations passed.
- Independent ModelConsumer and ProcessConsumer passed; manifest and diff checks
  passed. No laboratory was added to CI.

A parallel affected-suite run exposed an existing backup observation assertion
that required the very next event to be recovery. An isolated rerun passed.
The test now tolerates only expected in-flight `resourceReserved` states while
still requiring automatic recovery without refresh/write; other errors or stream
termination fail. Observation runtime code is unchanged. The full macOS/iOS
checks above passed with that correction. The only subsequent test change renamed
a private helper; the final focused suite and both consumers passed afterward.

Review compared the extracted sequence with MF07, resource/backup ownership and
persisted formats. Returned receipts are now validated before save. Existing
receipt recovery precedes intent artifact generation. A second synthetic native
source uses independent snapshot/intent/receipt types and no v1 adapter, including
rollback and shared-admission coverage. No remaining blocker was found in this
bounded scope. This is not an independent human review.

## Physical compatibility recovery

The disposable demo archives source `fdf22c3`. A new `recover-structure` stage ran
once on iPad and XR, reopening the MF07 local fixtures originally converted by
`f72c2e3`. Both passed. Old `convert`/`recover` stages were not replayed. No new
application edit or source seed occurred in these recovery stages.

Each stage recovered the exact stored receipt, legacy-to-native UUID map and
one backup, retained the later v2 edit, verified five records/topology/dates/
legacy property version/2-MiB binary contents, checked unchanged source SQLite
SHA-256, and observed the expected five local pending records. It used current
container URLs and did not reset a container or start a cloud session.

The inherited report text also mentions backup restoration: that restoration was
performed in the original MF07 creation stage, not repeated in these two recovery
stages. These runs establish receipt/data compatibility, not a new physical
restore certificate. Generic source-backup validation/restoration is covered by
local suites. Local probe source, raw reports, signing and stores remain outside
the repository. Demo processes were stopped after report collection.

## Remaining acceptance

Public bootstrap, historical/production stores, larger/staged/in-place conversion,
physical interruption, large-property cloud readiness and one authoritative
new-cloud mapping remain open. The synthetic second definition is test coverage,
not production support for another model. No beta/stable migration gate closes.

Final full CI is requested only after local/device checks and review; its result
will be recorded before merge.
