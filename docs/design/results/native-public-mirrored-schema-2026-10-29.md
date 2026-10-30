# Public native mirrored schema adoption — 2026-10-29

## Implementation and local verification

The public product adds explicit GraphDatabaseSchema selection to both
openMirrored shapes: a private-only store and a private/shared pair. No-schema
and current opens keep the previous model. validateIntegrity(of:) works on the
current local view of either supported native topology. The laboratory wrapper
now delegates to public methods; it no longer supplies another opening path.

A same-shape historical prototype exposed a pre-load requirement: catalog refusal
must occur before native mirroring can export its old protocol. The native factory
therefore sets standard Core Data model version identifier
GraphEvo.nativeIdentity.alpha.2. StoreSchema optionally requires it in persisted
metadata and includes the requirement in lease compatibility. All resource
metadata is checked before container construction/loading. Core Data records the
identifier on new stores; no manual stamping, migration, second coordinator or
identity repair is used. Entity hashes/columns and root alpha.1 protocol remain
unchanged. Incompatible unversioned alpha files are preserved and require fresh
paths under M13; v1 migration remains a separate mandatory workstream.

Full local suite: 513 pass (322 legacy, 107 store, 61 runtime, 23 model).
Selected Thread Sanitizer: 14 tests in four suites pass. Additional targeted
pre-load checks assert incompatibleStore specifically, preserve original readers,
and reject an incompatible secondary file before creating a fresh primary.
Both offline load orders and private-only routing are covered. The external
Swift 6 Release ModelConsumer passes local typed/observed operations and both
public mirrored overloads' early invalid-URL refusal without cloud credentials.
The generic iOS public private/A6 hosts compile. These are distinct checks.

## Public private-only device consumer

On the owner iPad (iPadOS 27.0), the final versioned public factory passed single
resource native setup, typed insert/query/observed initial state, full native
integrity, owner-boundary preparation and complete owned-row mappings. Existing
local-store reopen retained graph/node identities and values through the same
public opener. The reopened native owner remained alive. This is not independent
replica recovery or an export-completion barrier. The host source uses only
import GraphEvo with no package/testable/native-context access.

## Public paired device run and retained failures

The paired public A6 consumer uses the iPad owner and different-account XR
(iOS 18.7.10), separate fresh local resources and the approved Development
container. No cloud reset occurred in this increment. The final versioned run
passed recipient identity, both native setups, owner A3/B2 with 512-byte/10-MiB
files, full integrity and distinct boundaries, and the initial invitation call.
The original acceptance and a separate same-invitation continuation both returned
CKErrorDomain 11 (unknownItem). Neither was recorded as a successful acceptance,
and no new graph/share or participant file assignment was replayed.

An earlier unversioned public run failed during owner seed with generic Cocoa
error 134060; it never produced a completed fixture. Its stores/reports remain
untouched. A new fixture was used after adding the pre-load model-version gate,
not an automatic retry/conversion of that failed alpha seed.

Read-only diagnostics used documented CKShare/metadata reads separately from
functional consumer evidence. Owner server lookup found the share and the exact
invitation URL, but returned one participant, the owner; the intended recipient
was absent from that response. The XR matched the original recipient identity
but shareMetadata(for:) returned unknownItem, including a bounded visibility
observation. Signing inspection confirmed the same Development container and
environment as the earlier accepted laboratory build. No native mirroring
metadata tables or managed-record fields were reverse engineered or edited.
This observation does not identify the competing activity or reason the intended
recipient was absent after native persistence returned.

The final continuation persists only the same intended recipient on the same
prepared share using the existing public invite API. It asserts canonical Codable
invitation equality before writing a separate resumed transport: original graph,
recipient and capability must be unchanged. There is no replacement share, root,
node ID, metadata stamp or native share-assignment replay. The initial errors and
server observations remain part of the result regardless of continuation outcome.

## Completed paired public continuation

The one explicit same-recipient invite continuation returned a canonically
byte-identical GraphInvitation and used the original prepared share/capability.
The XR then accepted and independently recovered/exported the exact original
10-MiB body. Public participant file import (512 bytes) reached the owner;
replacement preserved ID/changed revision, reached the owner with exact new
bytes/checksum, and exported byte-exactly on XR. Participant deletion committed
once and was independently recovered by the owner. Owner cascade then removed
its owner and all surviving files, including the participant-added file; XR
recovered full A integrity count 0. The final owner check preserved B's exact
file and both distinct non-nil native boundaries, with no pending/unexpected
mappings. All functional calls used the public GraphEvo product.

Two ordinary read-only host launches produced no on-device stage report despite
CoreDevice reporting launch success; the maintainer saw a black screen. These
observations were not query failures or completed read stages. The standalone
CLI app delegate now starts a guarded request independently of viewDidLoad/scene
visibility. Distinct read-only tickets checked the existing replacement/deletion;
no write was replayed. Controlled launch with start-stopped, an explicit local
symbol target, the actual CoreDevice identifier and LLDB attach/detach completed
the blocked read and final stages. The debugger was detached before functional
work, with no expression evaluation or managed-state modification. Its startup
stack at dyld was the requested launch stop, not evidence of a Core Data deadlock.
The exact cause of ordinary reportless launches remains unproven.

The final result is positive for this bounded public private/paired adoption,
with retained initial failures and explicit continuations rather than a claim
of a clean first attempt. No library automatic retry, alternative merge policy,
new share/zone, identity repair or direct CloudKit record mutation was introduced.
The native-only laboratory result and public-product device result remain separate.

## Release scope

#90 passed reviewed macOS/iOS CI at e7b4e1f (40918720404) and merged into the
consolidation parent at ee21bdb3be6e8855adf6edf423e33dd6a6aa176b. #91's documentation
requirement passed both jobs at 8177689 (40920529202), was reviewed and merged at
a498ba2ccd7135b62c51e91142570e86aa23e199. Its prospective merge changed only the
three planning documents on top of accepted #90 implementation.

No integration/tag promotion, beta declaration, supported multiprocess claim or
v1 conversion is included. App/widget access remains required before beta. Keep
invitation readiness/error/retry semantics, broad conflict/crash/account/scale
coverage and mandatory v1 local/cloud migration open in the post-alpha register.

## Maintainer-requested causal follow-up

The [causal triage](native-public-causal-triage-2026-10-29.md) reproduces a host
launch acknowledgement defect and records two instrumented first-invitation
successes. It does not establish the exact cause of the historical black screen
or missing recipient. PR #92 remains draft pending that investigation; later
success must not close the retained incidents.
