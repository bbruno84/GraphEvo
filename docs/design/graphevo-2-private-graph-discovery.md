# Ordinary private graph discovery and recovery

Notes demo prerequisite after transactional File import (#193). The public
connection discovers existing owner-private GraphEvo graph descriptors and opens
ordinary replicas without fabricating a v1 conversion or MF10 authority.

## Public contract

`discoverPrivateGraphs(zoneNamePrefix:)` returns verified private references and
per-zone issues. Missing descriptors in unrelated zones are ignored; incompatible,
malformed and duplicate logical identities are reported. An optional explicit
consumer-owned zone prefix narrows discovery. Graph IDs always come from the
system descriptor, never the zone name. References bind container, environment
and account internally and expose identity, zone name and File capability.

`openPrivateGraph(_:at:)` rechecks the descriptor and current identity before
native changes. It creates an empty target or resumes an exact marked ordinary
replica. It refuses an unmarked existing target, even if empty, and never adopts
populated consumer data as a recovery destination. An existing authoritative
v1 graph continues through MF10's existing protocol.

Ordinary private binding publishes the existing graph descriptor independently
of sharing. Existing descriptors are validated, never overwritten to change
identity. Native service failures and per-record save errors propagate. No new
CloudKit record type, descriptor fields, node format or native schema is added.

## Ownership and persistence

Discovery/control requests join the existing private session gate and verify the
account before and after native work. They allocate no additional CKSyncEngine.

An ordinary bootstrap stores format-1 provenance in reserved root metadata,
separate from application properties and MF10 documents: operation UUID,
account-bound route, native store UUID and readiness. Startup reapplies runtime
read/write admission while incomplete. Session format 11 introduced ordinary
pending routes; definitive deletion now uses session format 12. Earlier state is refused unchanged, not upgraded
or erased. Consumer applications use fresh alpha session namespaces as needed.

Recovery uses the existing on-disk inventory, bounded batches and asset spool.
Endpoints precede edges; owners precede attachments. Retry reuses the operation
and reconciles previous partial inventory rather than replaying consumer bodies.
A public store is returned after structural validation and zero outgoing import
feedback. Native/scope cleanup failures remain visible. Completion records a
recovered current server inventory, not global synchronization completeness.

The old zone-creation/deletion behavior is not expanded by this increment;
definitive deletion and prevention of old-owner resurrection are the next
separate prerequisite. Supported clients must cooperate through GraphEvo.
