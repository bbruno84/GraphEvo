# MF09 — explicit local v1 conversion and opening

## Scope

MF09 connects the existing MF07/MF08 conversion to ordinary ContextManager
opening. It remains package-only, on the S04 custom-sync path. The caller requests
one stopped known-model v1 source, one distinct destination, stable GraphID and
operation UUID, a current backup root and a reason. It does not discover sources,
intercept default public openers or start/bind cloud sessions. Historical source
acceptance, public facade activation and authoritative new-cloud cutover remain
separate gates.

The native conversion, source fingerprint, backup artifact, UUID mapping and
receipt use the existing implementation and durable formats. There is no new
manager, registry, application-data format or schema revision. Existing v1 binary
properties remain Data; moving them to attachments belongs to the consumer.

## API and outcomes

`GraphContextManager.openGraph(convertingLocalV1: GraphStoreMigrationRequest,
limits: GraphV1ConversionLimits = .init()) async throws -> GraphV1BootstrapResult`

`GraphV1BootstrapResult` is Sendable and contains:

- `conversion: GraphV1ConversionResult`: the durable native receipt, recorded
  backup’s current URL and any post-commit cleanup warning;
- `opening: Result<GraphStore, any Error>`: ordinary native availability after
  conversion, distinct from data commit.

Before native commit, failures throw and no graph is returned. After commit,
opening/cancellation/native-cleanup failures remain an `opening.failure` beside
the successful conversion result. They never imply that conversion was rolled
back or discard its mapping. An error releasing the backup pin remains a
cleanup warning;
ordinary opening is attempted independently. A failed native detach retains
ownership and can prevent opening, requiring restart rather than another owner.

The consumer can use `result.opening.get()` after retaining/inspecting conversion
information. On subsequent launches it normally opens the converted graph with
`openGraph(id:at:)`. To recover an uncertain bootstrap it resubmits the original
explicit request and current URLs. The native receipt is validated before any
reapplication; later ordinary v2 edits remain preserved. The consumer persists
request IDs before first invocation. No sandbox path is written to a new journal.

## Admission through final opening

ContextManager reserves the GraphID and canonical destination before source
inspection. The admission lasts through conversion, native cleanup, full ordinary
opening and final availability checks. Same-ID open/create, same-destination
aliases and concurrent conversions are refused while it is held. The final opener
uses an internal generation token; ordinary callers cannot bypass this admission.
A late release cannot remove a newer admission. Existing active handles are not
closed by bootstrap, and an already registered GraphID cannot be silently rebound
to another file. Other graph IDs/resources continue independently.

The shared migration runner still acquires the restricted read-only source and
normal destination ownership claims. Its public package entry refuses a bootstrap
reservation; only the internal bootstrap path enters the same protected runner
under the wider admission. Ordinary open/create also refuses an active internal
migration for that GraphID. Failed source validation releases bootstrap admission
without creating a destination or backup. Failed commits retain their existing
backup pin and rollback/retry rules.

## Local-only and cloud boundary

A GraphID already bound in an explicitly started cloud session is refused before
conversion. Bind/accept/send/fetch admission remains closed for a bootstrapping
graph; unrelated graphs and engines are not stopped. A cloud session restored
with a conflicting binding during bootstrap reports busy, and a post-commit check
returns the committed receipt with failed availability rather than activating it.
Bootstrap does not restore a cloud participation as an opening side effect.
Session-generation changes during a binding check are refused conservatively.
If a session is still opening and its binding document is unknown, bootstrap
returns busy promptly rather than awaiting account/network startup.
No engine state is reset or transferred.

The consumer must serialize cloud configuration for this graph with bootstrap.
A stopped session document is not discovered from arbitrary filesystem locations;
starting it later is an explicit separate action, not certified cloud cutover.
This local increment does not decide which converted graph/mapping becomes the
single authoritative cloud writer.

## Source and data validation

Support remains the exact known twelve-entity v1 physical model. Source and
external writers must be stopped; in-process legacy/native ownership exclusion
is enforced. The conversion preserves supported kinds, graph references,
properties, tags/groups, optional dates and legacy property versions. Unknown
schemas, ambiguous wrappers/nulls, reserved metadata, stale/replaced sources,
foreign destinations and unsupported values remain refusals rather than lossy
conversion. Realistic fixtures exercise invoices/categories, relationships,
actions, opaque archived values, Decimal, dates and a 2-MiB binary property.
They are synthetic and do not close production/historical-source acceptance.

S04 is the selected target; historical MF07/MF08 S03 reports retain their actual
scope. Complete backup verification precedes the atomic root/records/map/receipt
commit. Ordinary native opening then performs its own full structural/payload
admission and checks consumer read availability, including stored participation
gates. A conversion receipt alone is not readiness, CloudKit acknowledgement
or a general migration-completeness certificate.

Limits remain 10,000 records, 100,000 native rows and 32 MiB weighted payload by
default, with the existing hard ceilings, PH, artifact, mapping and receipt bounds.
No limit is raised, default opener changed or incompatible alpha store upgraded.

## Verification and delivery

Deterministic tests cover successful S04 availability with backup/source proof,
restart and same-volume relocation, unchanged UUID mapping after later v2 edits,
post-commit opening failure without reapplication, pre-save/post-commit
cancellation, early/final-opening concurrency, active/foreign registrations,
invalid/replaced source, live legacy exclusion and retained detach quarantine.
Injected cloud tests distinguish unrelated bindings from the target's existing
or concurrently restored binding; they make no real-network claim.

Physical laboratory checks use fresh local fixtures on iPad/XR with no cloud
session. They verify source retention, opened S04 contents/topology/binary data,
portable backup, then restart recovery with the same IDs and a later v2 edit.
Hard power loss, external-process writers, production historical stores, scale
and cloud activation remain separate gates. Labs and raw device/store artifacts
stay local and outside CI.

Workflow: local/device checks, review/corrections, one full CI checkpoint on the
reviewed source, then authorized integration into `codex/graphevo-2`.

## Local review checkpoint

Local checks pass 923 macOS functions (331 legacy, 487 store, 76 runtime,
29 model), iOS store/model suites plus the final fifteen bootstrap tests, both
independent Swift 6 consumers, manifest and diff checks. Review adds the consumer
read-admission check so stored participation metadata cannot appear locally ready,
and covers a conflicting session restored while conversion is admitted. Pending
account startup refuses promptly without source/destination effects. Native
detach quarantine remains owned; a post-commit error cannot hide the receipt.
The [six-stage physical report](results/local-v1-bootstrap-2026-11-02.md) records
iPad/XR conversion, restart and final-source recovery. Final reviewed-source CI
is recorded at integration.
