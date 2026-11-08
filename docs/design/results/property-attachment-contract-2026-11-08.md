# Property and attachment contract — 2026-11-08

Scope: `codex/v2-property-attachment-contract`, based on integrated File sync
`4751b4b3` (#190). This is implementation and bounded acceptance evidence;
integration remains a separate reviewed step through
[PR #191](https://github.com/bbruno84/GraphEvo/pull/191).

## Result

Scalars and recursive supported collections use properties. Raw Data and fixed
JSON Codable values use keyed attachments. Ordinary insertion/replacement accepts
0 through 2,097,152 bytes and refuses larger encoded bodies before native edits.
Native v1 conversion extracts recoverable binary properties without that cap,
retaining original owner/key/bytes/version provenance. A scalar edit preserves
oversized migrated content; explicitly setting that content again is refused.
Current contexts select fresh S06/S07, refuse S04/S05 unchanged, and retain the
historical factories. File semantics remain unchanged.

## Native CloudKit on physical devices

A signed Release host used a physical iPad on iOS 27 and an iPhone XR on
18.7.11, with different accounts, private/shared Development databases and the
real native transport. The fixture is retained under
`Experiments/PropertyAttachmentProbe`. Private stores, invitation/account
artifacts, launch receipts and reports remain external to the repository.

1. The iPad created a controlled stopped v1 source with a 5 MiB + 1 byte Data
   property, collections and a scalar. Public staged conversion extracted the
   oversized keyed attachment. The destination added a raw attachment of exactly
   2 MiB, a Codable attachment and an independent 256 KiB File. A refused
   over-limit patch preserved the earlier scalar. Authoritative migration
   activation published the converted graph and prepared the invitation.
2. A genuinely empty XR shared replica recovered the exact raw bytes, Codable,
   collections and File metadata/digest. The iPad writer remained live through
   this independent observation. A 4 KiB query budget accepted count and a
   selected-property projection but refused complete materialization.
3. Both contexts were closed with receipts before installing the final build.
   The XR resumed its persisted invitation, verified revision 1, replaced raw
   and Codable fields and published revision 2 while retaining migrated content.
4. The iPad reopened, independently verified revision 2, replaced those fields
   again and published revision 3. Its writer remained alive while the XR
   reopened and verified revision 3, including unchanged migrated and File bytes.
   Both owners then closed with explicit receipts.

Only invitation/fixture metadata crossed the local test harness. Binary content
reached the other device through CloudKit. No native store was copied as a fresh
replica, no consumed mutation was replayed, and no manual device taps were needed.

## Findings corrected during implementation

The initial external seed harness incorrectly attempted ordinary binding of a
converted store. The library refused it correctly; the corrected fresh run used
mandatory authoritative activation. This was a harness error.

Native invitation discovery exposed a production decoder error: CloudKit returns
the File capability as numeric 0/1 rather than retaining an NSNumber Boolean's
runtime type. Encoding/decoding now uses explicit numeric 0/1, with a regression.
The accepted invitation was resumed; it was not accepted or seeded a second time.

A pinned SQL generation did not by itself retain an old Core Data external
binary reference after replacement. S06/S07 now keep a finite Foundation read
intent until content detachment and context reset. An unassociated read intent
also excludes the same presenter's writer. A deterministic cold-fault regression
proves the writer waits and the reader receives the original bytes. File URL
callbacks retain store admission and their existing immutable-revision intent,
without holding the external-binary store grant. Existing replacement/reclamation
checks cover that distinction. Tests that deliberately waited for a writer from
inside a read were updated for the selected S06/S07 admission contract.

Metadata listing uses fixed dictionary projections, including a pending-change
session path; it never materializes an owner's other attachment bodies. Full
materialization retains byte charging. A per-query named-attachment presence
check avoids repeated empty owner fetches for graphs without named attachments.

## Validation

The initial contract checkpoint passes all **769 macOS v2 tests**: 645 store, 91 runtime and
33 model tests. It includes the 2,000-record query capacity fixture with its
unchanged step budget and the complete large-publication fixture. The legacy
macOS facade passes all **331 tests**. Manifest validation and `git diff --check`
pass. Two Swift 6 consumers pass, including separate macOS
processes and public staged v1 bootstrap. Three negative compile fixtures reject
Data conformance, the binary GraphValue case and the generic encoded case at the
intended public boundary. iOS 18.5 Simulator passes 82 affected value/native
migration/invitation/model tests and 142 coordination/runtime tests, without
skips. The additional long-Unicode/embedded-null native representation case
passes with the four-test iOS property-storage suite. These groups overlap and
are not an additive unique-test count.

The first broad run and an isolated repeat exceeded the existing 120-second
hang guard in `publishesAndRecoversSeedAboveTheFormerAggregatePayloadLimit`.
A controlled local-only counterfactual with the read grant disabled completed in
84.718 seconds. This is diagnostic evidence, not an allowed shipping mode.
With the selected read protection retained, the complete Debug publication and
independent recovery passed every assertion in 214.782 seconds; the final broad run repeats that
success in 214.120 seconds. At that checkpoint, the capacity
case received a five-minute hang guard; ordinary activation cases retained their
explicit two-minute guards. No correctness assertion, query work/byte budget,
writer exclusion or read protection was removed. No diagnostic environment
switch or alternate read mode from this counterfactual remains in the fixture.

These are historical timings from the initial contract checkpoint. The subsequent
[cost investigation](initial-publication-cost-2026-11-08.md) identifies and corrects
two local regressions while retaining native read coordination. The same complete
fixture now passes in 12.83 seconds Debug and 12.59/12.66 seconds Release, with
the original two-minute hang guard restored. Final validation passes 773 macOS
v2 tests, 331 legacy tests, both Swift 6 consumers and 197 affected iOS tests;
physical iPad/XR replicas reopen and verify the existing values. The investigation
report separates synthetic local timing from physical correctness and unmeasured
network/device performance. Broader PA05 acceptance remains open. Core Data also
emits external-reference clone diagnostics during temporary fixture cleanup;
passing assertions do not turn those messages into independent integrity certificates.

## Limits

This closes the selected contract and bounded cross-account exchange. It does
not close broader PA05 capacity/memory acceptance, production source matrices,
50 GB device acceptance, midstream fault coverage or distributed field conflicts.
Attachments still materialize complete bodies. File download remains synchronized,
without on-demand transfer or progress. No hosted CI checkpoint, merge or tag is
implied by these results.
