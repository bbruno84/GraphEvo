# Ordinary private discovery and recovery — 2026-11-08

## Scope and review

PR #194 follows transactional File import (#193, integrated `29ba5d12`).
The public connection discovers existing owner descriptors and recovers ordinary
private graphs without fabricated v1 provenance. No native schema or CloudKit
record format changes. Session state advances from 10 to 11; previous state is
refused without rewriting. Definitive deletion and Notes UI remain subsequent work.

Focused source review covered identity verification before/after transport,
ambiguous descriptors, existing-target refusal, pending read/write admission,
operation reuse, asset ownership through import and cleanup failures. No unresolved
actionable findings remain on this increment. Review does not certify later deletion.

## Local validation

- macOS v2 profile: 778 functions (651 store, 94 runtime, 33 model), before final
  defensive hardening. Final affected suite passes four functions (including both
  ordinary and interrupted/restarted recovery cases).
- iOS Simulator: 51 functions across private discovery, activation and native
  invitation suites, before the final descriptor hardening and format-10 test.
- Both Swift 6 consumers independently pass on final sources.
- Manifest and diff checks pass. No hosted CI checkpoint requested.

Recovery verifies note properties, keyed attachment, File bytes and endpoint
identity, zero outgoing import feedback, reopen, wrong-account reference refusal
before native creation, and refusal of populated unmarked stores before account
claim. A fault after inventory application leaves the ordinary replica gated;
new owners resume the durable operation. Duplicate IDs produce no usable reference.
Unsupported descriptors report per-zone errors. Format-10 session bytes remain
unchanged after refusal. Synthetic services are not real CloudKit evidence.

## Physical CloudKit

Two fresh Release trials pass on the connected iPad using actual Development
CloudKit. The second trial includes final descriptor hardening. An ordinary graph
publishes one note, a 128 KiB cover, a 256 KiB File and its relationship. Direct
server reads verify identities and bytes before closing the source owner. A fresh
catalogue/session and empty SQLite discover and recover the graph, with zero
outgoing feedback. The recovered replica closes and reopens with matching content;
all owners and connections close successfully.

External evidence directories are `ge-private-discovery-ipad-20261108-a` and
`ge-private-discovery-ipad-20261108-b` under the local temporary evidence root.
Generated stores, account values and reports are not committed. No store copying,
v1 conversion or sharing invitation is used. These are independent sequential
sessions on one physical device, not two devices with the same account. The XR
uses a different account and remains suitable for later shared Notes acceptance.
