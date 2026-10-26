# V02 — fresh accepted-share replica and read-only save behavior

Status: the fresh accepted-share replica was observed; the attempted read-only
write **persisted locally** despite `canUpdateRecord = false`. The owner's data
remained unchanged during bounded observation. This does not establish local
write rejection, permanent remote non-replication or a server rejection.

## Setup and native operations

This continues [the initial cross-account control](v02-cross-account-smoke-2026-10-26.md)
using its disposable run `8A6E6A45-2D7D-44C9-B127-32A552C1F773`.
Case/probe `605155F3-6AC9-4A5E-B248-15BC88569647` used the iPad owner
(iPadOS 27.0, 24A437) and other-account XR (iOS 18.7.10, 22H374).
A-001's expected value was `alpha-from-participant`; B remained owner-only.
The owner changed only the authorized participant's A permission from read-write
to read-only and persisted the share through Core Data. Public permission stayed
`.none`; no participant was added/removed and neither graph was purged.

The XR opened **two new isolated stores**, private/shared, with a permanently
consumed probe identifier. It invoked no invitation or acceptance API. The
already accepted A share imported automatically: exactly three A rows in shared
scope, no A private copy and no B in either scope. Values, links, normalized
record/share identities and read-only metadata matched the owner's fixture.
Its two store identifiers differed from the original participant stores.
This supplies V02.9 fresh-replica evidence, distinct from a local reopen.

## Actual write attempt and independent owner result

The probe recorded the native advice, then deliberately performed one real
`context.save()` regardless of that advice:

| Observation | Retained result |
|---|---|
| `canModifyManagedObjects(in:)` for the shared store | true |
| `canUpdateRecord(forManagedObjectWith:)` for A-001 | false |
| Attempted synthetic value | `alpha-readonly-attempt` |
| Save returned success | true |
| Local save errors / fresh-context read errors | none |
| Fresh private-context read of the shared row | `alpha-readonly-attempt` |

The probe remained open for 60 seconds after the attempt, without retrying,
restoring a value or hiding a local save behind a permission guard. Five completed
native export events were successful and no export failure was reported. These
container-level events contain no per-record acknowledgement and do not prove
that this mutation was uploaded, rejected by the server or permanently discarded.

A separate owner process opened the original owner stores and sampled for a
full 60 seconds, overlapping the participant window. A-001 retained
`alpha-from-participant`; no unexpected owner snapshot was recorded. A's other
values, links and record/share IDs remained unchanged. B's entire DTOs were
identical to the pre-permission-change baseline. This is a bounded observation,
not a live-import-into-an-already-open-owner or synchronization latency guarantee.

After retaining final reports, all three processes were explicitly terminated.
The probe stores were detached and the CLI refuses to reopen that consumed
path. Read-write restoration was **not executed**: a locally persisted probe
mutation must not be released by later granting write permission while that
store might export it. No quiescence acknowledgement is inferred from detach
or termination. The ordinary participant stores remain separate and unmodified
by this probe. Follow-up revocation can start from the retained read-only state.

## Provenance and evidence

Demo source `b3e23b1`, app Swift SHA256
`a790aaa80a6d05985ed67fb2a46da7c255bd826719bba006a87d3680e76191d0`.
The app suite passed 73 tests, including a real SQLite fresh-context read after
save and checks for one attempt, complete sampling and consumed-path guards.
Simulator tests are not cloud evidence. Xcode 27.1 (27A9275), Swift 6.4
(`swiftlang-6.4.0.34.1`) in Swift 5 language mode, GraphEvo pin
`4dc0a7f9a717ee535e9b630b998cd6c869a2d538`. Signed Development entitlements,
runtime test destination, source provenance and provisioning for both devices
were verified before installation. No other device or Production resource was used.

Intervals are UTC on 2026-10-26:

| Stage | Interval UTC | Final JSON SHA256 |
|---|---|---|
| owner-readonly | 07:29:31–07:30:07 | `28b72193a598f23088dc219cb5ce1933cb95fd9d82702ff126f7b69560597009` |
| participant-readonly-probe | 07:30:28–07:31:33 | `766364c57ff84ca0e9ddeaa6bc962eea1feefdec557411739d03198a8c8eb249` |
| owner-observe-readonly | 07:31:00–07:32:04 | `883bf85c37c9330e6cf72921875272e4977b41900dcc3c980b84f3d412f19844` |

All final reports were retained with no stage errors, completed native event
failures, trace-write failures or dropped entries/events. The archive
`2026-10-26-V02-readonly-605155F3-6AC9-4A5E-B248-15BC88569647` retains reports,
traces, manifests, build/install/stop logs and an independent comparison summary.
Account identifiers, invitation URLs and raw artifacts remain outside Git.
No wipe, app removal, store deletion or fixture rewrite occurred.

The intended application path must honor public permission advice before
mutating an object. The deliberate guard-bypass above is a diagnostic control,
not a proposed GraphEvo behavior. After the maintainer clarified the functional
sharing objective, no further investigation of internal export behavior is
planned for this case.

The result requires a future API to distinguish permission advice, local
persistence and remote acceptance. It does not yet choose that API or establish
all timing/permission cases. V02.5 remains partial rather than being labeled a
successful read-only write-rejection test.
