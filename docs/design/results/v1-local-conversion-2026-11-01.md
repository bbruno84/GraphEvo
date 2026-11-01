# MF07 — local v1 conversion result, 2026-11-01

Implementation source: `f72c2e32809528b7b1a85a6284ee16ee985cd2b9`, based on #128,
[PR #129](https://github.com/bbruno84/GraphEvo/pull/129). The
[contract](../graphevo-2-v1-local-conversion.md) defines the supported local route.
The single full [CI checkpoint #331](https://github.com/bbruno84/GraphEvo/actions/runs/41336556416)
passes after local/device review on `f24029a02d7c7ea86d7400758c07236e9f28959f`.
macOS: 886 functions plus both consumers. iOS: 884 functions / 987 passed
invocations, one known legacy temporary-directory-alias skip and no failures.
CI uses macOS 15 / Xcode 16.4 / Swift 6.1 / iOS 18.5. Final integration notes
are documentation-only; shipping source/tests match the checkpoint exactly.
No cloud conversion/activation is performed.

## Local checks

- Full macOS package: **886 functions** pass (331 XCTest, 456 store, 76 runtime,
  23 model), no failures.
- Selected iOS 18.5 runtime/store/model: **554 functions / 657 invocations** pass,
  no failures/skips.
- Both Swift 6 ModelConsumer and separate-process ProcessConsumer pass.
  Manifest and diff formatting checks pass.
- The affected backup/publication/conversion group passes 48 functions after
  review corrections. Existing negative fixtures emit expected Core Data errors;
  successful summaries, rather than the absence of diagnostic text, are checked.

Thirteen new functions/eighteen invocations cover:

| Area | Evidence |
|---|---|
| Complete local data | Five primitive fixtures retain values, decimal, nested data, URL/date, binary/archive bytes, tags/groups, dates, optional endpoints and action references; no implicit attachment. |
| Original preservation | The source SQLite SHA-256 is unchanged; the original and restored backup remain usable through the v1 facade, including exact 2-MiB external-size binary content. |
| Legacy metadata | Per-property native appDataVersion and an ordinary application property of that name are preserved without version admission. |
| Fresh target | Different native store UUID, S03 model, random durable logical IDs and one normal local-author PH generation; only the five application records become pending. |
| Receipt recovery | Repeated request/restarted manager recovers the same map/receipt and one backup, preserving later v2 edits. |
| Invalid requests | Record/row/payload budgets, reserved metadata, backup failure, foreign destination, wrong operation and changed source refuse without overwrite. |
| Transaction failure | Throw after all native application effects/receipt have been staged; rollback leaves no openable graph and retry reuses the pinned verified backup. |
| Cancellation | Before save rolls back; after save returns committed proof. Retry does not duplicate backup or application records. |
| Source ownership | Live v1 writer refused; restricted legacy reader cannot write or mix with a normal reader alias. |
| Null/opaque values | Unambiguous null retained or ambiguous value explicitly refused, never omitted. Known wrapper values retain a secure opaque archive and semantic canonical fingerprint. |
| Relocation | Same-volume movement of source/destination/backup root recovers using current URLs; no path is serialized. |
| Cleanup failure | Committed proof plus visible cleanup error; native claims stay reserved and another graph continues. Quarantined fixtures are retained. |

The read-only source-model audit also compares `Model.swift` against v1
`origin/develop` at `4dc0a7f9a717ee535e9b630b998cd6c869a2d538`: only the fresh
factory refactor differs; entity/attribute construction is unchanged. This is
source inspection, not certification of an app's production file.

## Review findings and corrections

The old source cannot always initialize query-generation tracking while opened
read-only. Added a narrowly restricted stopped-source reader and read-only
structural validation mode; normal v2 reads remain pinned. The alias compatibility
check includes this mode, preventing a normal reader from borrowing the unpinned
owner. Existing runtime ownership and no-write rules remain enforced.

Review also preserved native property versions, bound the map/receipt to actual
legacy mappings or retained deleted IDs, kept fixed-ID backup reuse, and retained
precommit cleanup failures separately from a successful native commit. Conservative
preview and final native-change limits prevent a converted graph whose initial
transaction cannot be processed by the normal PH path. No remaining blocker was
found within the explicitly supported local scope.

Early fixture corrections are retained in the local development logs: the v1
encoder cannot write native UUID values, and current Core Data rejects assigning
non-NSCopying AnyCodable wrappers directly. Fixtures now use actual v1-supported
UUID strings/archived Data, without changing v1 behavior to make a test pass.
Historical native-wrapper source acceptance remains open. Ambiguous stored nulls
are rejected explicitly rather than normalized from missing data. Decoder/value
refusal is not a successful mandatory conversion of all historical inputs.

## Physical local conversion and restart

A disposable signed demo archives exactly `f72c2e3` and adds only an external local
probe. Signing identifies the authorized Development test container, but the
protocol creates no CloudKit configuration/session and invokes no fetch/send.
There is no account/share or cross-device synchronization certificate here.

Fresh independent local fixtures on **iPad and XR** each pass two reserved stages:

1. `convert`: create a real v1 source with Entity/Relationship/Action, optional edge
   endpoints, missing creation date, tags/groups, legacy detail version and 2-MiB
   Data. Convert into a distinct S03 store. Verify exact records/topology/dates/
   versions/bytes, new native store identity, unchanged source checksum and five
   normal pending PH records. Verify the legacy `.geb`, restore it to another
   temporary location and read its original ID/binary through the v1 facade.
2. `recover`: explicitly terminate/restart the acknowledged process, edit a v2
   value, repeat the identical conversion request and recover the same receipt/map
   and one backup. Verify the newer v2 value survives, original checksum/data stay
   unchanged and normal pending work remains coherent.

All **four stage reports** pass. Source validation afterward uses the restricted
read-only old-model reader. No mutation stage is replayed, no native store is
copied into a fresh target replica, no container is reset, and no source file is
relabelled. Source/probe hashes, signing, receipts, native files and reports remain
outside git; both laboratory apps are closed after collection.

## Remaining acceptance

This closes the bounded local feasibility item only. Default openers still refuse
old schemas; explicit package-only conversion must precede ordinary opening.
Production/historical inputs, ambiguous null resolution, native wrapper stores,
paired sources, automatic public bootstrap, large staged conversions, physical
kill/power-loss and external-process writers need their own acceptance.

The 2-MiB value is preserved as Data, not inferred as a file. It exceeds the
existing inline cloud allowance; local preservation does not prove CKAsset
publication. Before new-cloud activation, settle large properties and select one
authoritative converted graph/mapping: independently converting multiple devices
must not create competing random-ID imports into the same cloud graph. Old-cloud
format migration remains outside this increment. No schema/cloud/session format
or beta/stable gate is changed.
