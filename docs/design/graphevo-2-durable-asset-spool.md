# GraphEvo 2 — durable temporary CKAsset spool

Status: integrated through [PR #144](https://github.com/bbruno84/GraphEvo/pull/144),
with reviewed [full checkpoint #41715897139](https://github.com/bbruno84/GraphEvo/actions/runs/41715897139)
on `ae0d50ef688bb0ca5d7088abb12ebfcc0e21f50a`.
Read with [T04](graphevo-2-cloud-assets.md), [T01](graphevo-2-record-transport.md),
[MF10](graphevo-2-authoritative-cloud-bootstrap.md) and
[controlled store access](graphevo-2-controlled-store-access.md).

## Ownership and publication

The ContextManager remains the single synchronization entry point. A graph has
one coordinated native owner; the runtime retains its interprocess writer fence
through synchronous Core Data preparation, awaited temporary-file publication,
and the final Core Data save. The file phase cannot interleave another local
writer on that store. A failed or cancelled phase rolls the context back; a
successful native save remains committed even if cancellation arrives after it.
The transaction-local Session is reused under the same writer fence.

Attachment content remains in the S04 Core Data properties as the permanent
local representation. The spool is transport state, not an application file
store. Ordinary Data, arrays, dictionaries and Codable values remain in their
serialized property payloads. CF01 wire format 3 and the per-attachment 10 MiB
ceiling are unchanged. This increment adds no public file path or native model
field.

Outgoing files live under a store-UUID-derived private directory beside the
SQLite store, so a quiescent whole-directory backup includes a frozen attempt.
Incoming and sent-result files live under the private engine-session directory.
Every reference binds a role, account/container/environment, graph/zone,
record name, namespace, file ID, byte count and SHA-256; outgoing references also
bind the native store UUID and PH epoch. Durable records contain references and
small CKRecord envelopes with an empty asset placeholder. They contain no SDK
staging URL, absolute sandbox path or attachment body. Only the current native
owner supplies a root URL at runtime; it is omitted from batch coding and
equality. SDK CKAssets point at retained owned files until the native send
settles. Referenced bytes are checked against the saved digest before an offer,
receipt comparison or import.

The root is published with a private marker; individual files are created
exclusively, written in bounded chunks and synchronized before their reference
can enter the graph or session document. Files remain owned until the exact
related graph transaction or session consumption is durable. A failed
publication may leave an orphan, which a later verified opening/preparation
prunes. Startup checks ownership and length without loading every body; full
reads verify the digest on demand. A missing referenced file refuses reopening
without modifying the durable queue. A corrupt body refuses consumption and
retains the queue and previous local attachment. Directory copying still needs
a closed, quiescent source and a complete tree, including the spool. These
steps do not constitute an atomic filesystem/SQLite power-loss certificate.

## Budgets and compatibility

The outbound preparer limits one attempt to 32 MiB of attachment bodies. This
is a work-window limit; later attempts can send remaining records. The 32 MiB
graph transport and engine document limits still apply to serialized control
metadata and ordinary payloads, not the sum of CKAsset bodies. MF10 seed and
verification manifests charge inline payload bytes separately and process
records individually. A complete initial replica can exceed 32 MiB in total
asset content. The 10 MiB per-attachment limit and the record-count and
native-row limits remain. The
[transport policy](graphevo-2-record-transport.md) defines the current ordinary
payload and per-request limits. No total
database byte limit is inferred from the temporary work window.

The engine session format advances from 7 to 8 and the graph transport format
from 2 to 3. Earlier alpha operational documents/attempts are refused unchanged;
there is no silent conversion, relabeling or erasure. The native S04 schema,
consumer data, mandatory v1 conversion and CloudKit record wire formats do not
change. A production cutover must start with admitted fresh operational state
or a separately reviewed migration. Whole-directory backups remain necessary
for a frozen outgoing attempt.

## Physical private checkpoint — 2026-11-04

The [device result](results/durable-asset-spool-device-2026-11-04.md) verifies
40 MiB plus empty/control assets on same-account iPad/iPhone: restart before
send, restart before import, exact content/references, bounded control archives,
cleanup and another fresh replica. Eight reports pass; one original probe
assertion fails on unrelated global zone events and is followed by a guarded
read-only continuation, without import replay. No shipping runtime change is
needed. This closes the bounded private spool checkpoint; broader gates below
remain open. Neither restart occurs during file/native publication or power loss.

## Bounded evidence and open gates

Local tests cover reference recovery after session/store restart, compact
serialized queues for a 10 MiB file, missing/tampered file refusal, exact
cleanup, cancellation/rollback at the runtime boundary, partial/ambiguous
receipts, conflicts and a 36 MiB attachment seed with an empty peer. Synthetic
drivers exercise the native outbox offer path but do not establish real
CloudKit delivery, physical interruption, account acceptance or production
memory/network latency. Native framework fetches may still materialize a page
of downloaded assets before GraphEvo stages them; no metadata-only CloudKit
fetch or public streaming progress is promised. Broader performance and device
gates remain in the post-alpha checklist.
