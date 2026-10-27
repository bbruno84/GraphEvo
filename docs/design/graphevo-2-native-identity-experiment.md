# C02b — native identity lookup experiment

Status: isolated prototype after the accepted cost-matrix direction. Parent:
`c4b6745`. No default model, publicly selectable store-opening path, native cloud schema or
integration branch changes. This experiment tests the representation before
integrating a new persistence layout.

## Hypothesis and scope

Add two optional String attributes and a compound fetch index to a fresh copy
of each application node entity in a separate native model. Keep archived
GraphID/NodeID metadata as the migration source/cross-check. Compare full-inventory
public reads/patches with native exact-identity lookup plus target/reference and
membership checks, and measure explicit full integrity validation separately.
Application nodes store graph/node UUIDs; hidden root and membership nodes store
the graph UUID with a nil node UUID for selective anchor lookup. Catalog reads
fetch only roots. The native fields are routing data, not Core Data URIs or CloudKit identifiers.
There is no native uniqueness constraint or cross-device uniqueness guarantee.

The prototype must reject duplicate indexed identities across every node kind,
foreign endpoints/membership, missing activation, missing/mismatched columns,
malformed requested payloads and unsupported edits. Pending inserts/patches/deletes
must remain visible. Point lookup does not certify unrelated nodes: full integrity
validation remains an explicit operation. The laboratory adapter reuses normal runtime leases, serialization, scopes and
commit guards. The default public adapter retains its existing
full-inventory semantics; this probe is not a transparent faster replacement.

## Checks and measurements

| Check | Required evidence |
|---|---|
| Default-model boundary | Prototype changes hashes; default Model.makeModel remains unchanged; no automatic opener/migration added |
| Local conversion | Closed, owned synthetic source; complete directory backup; migration from a disposable source copy to a new destination; original source unchanged; optional columns initially nil; explicit validated backfill/activation |
| Data preservation | Graph/node UUIDs, all node kinds/endpoints, tags/groups, null/opaque/binary values, dates, attachment identity/owner/exact content |
| Correctness | Duplicate identities, inconsistent/missing columns, graph isolation, endpoint membership, staged nodes, pending changes, rollback, requested payload errors; global corruption reported by full validation |
| Cost | Fresh Release processes, 100/500/2000 nodes, several graphs, file-bearing graph; full vs targeted read/patch/missing read and explicit integrity cost; same data, disclose different validation scopes |
| Exit | Retain results/failures and choose whether native columns justify integrated layout/migration work; do not claim complete C02 or native sharing acceptance |

Use Apple's [fetch-index description](https://developer.apple.com/documentation/coredata/nsfetchindexdescription)
and [inferred mapping](https://developer.apple.com/documentation/coredata/nsmappingmodel/inferredmappingmodel%28forsourcemodel%3Adestinationmodel%3A%29)
APIs. Optional additions can be eligible for inferred migration; actual conversion
and bytes must be tested. The local prototype uses an explicit migration manager
and new destination; it does not enable automatic migration on library opens.
Native CloudKit assignment/import, paired-store conversion, interrupted conversion,
returning old clients and mandatory v1 local/cloud migration remain gates before
adopting this schema. No raw logs/stores or identity transports enter Git.


The first harness also times relationships, actions and a 500-endpoint action,
so a fast Entity-only result cannot hide reference-validation fan-out. Native
columns with/without a configured index are separate migrated stores. Point
operations use normal GraphStore runtime scopes through the package-only lab
opener; complete graph validation is measured separately. A missing/corrupt
column can look absent to point lookup and is caught by full validation: this is
an explicit integration gate, not an accepted production absence contract.
