# GraphEvo 2 — identity-only native schema (S02)

Status: selected alpha revision following maintainer decision M16. This supersedes
[S01](graphevo-2-persistent-schema.md) for explicit `.nativeIdentity` openings.
The public schema choice remains `.nativeIdentity`; its physical model identifier
is now `GraphEvo.v2.schema.2`. Default/current opening paths are unchanged.

## Shape and responsibilities

Retain the twelve original entities, their relationships, optional timestamps,
property encoding/external-storage behavior and existing per-property
`appDataVersion`. Add only optional String attributes `ge2GraphID` and
`ge2NodeID` to Entity, Relationship and Action, with no defaults. Retain the
binary compound `(ge2GraphID, ge2NodeID)` index on each node kind. No uniqueness
constraint, new relationship or property index is introduced.

`ge2GraphID` projects graph membership; `ge2NodeID` projects the stable logical
node UUID. The legacy facade ID is computed from local Core Data identity and
cannot replace that UUID across replicas. Existing logical metadata, hidden
catalog/membership links, assignment rules and projection consistency checks
remain intact. Optional native fields accommodate migration/partial imports;
application operations still require valid identity and graph boundaries.

Remove `ge2DataVersion`. GraphRecord has no application-version field and
GraphModel has no format declaration. There is no format registry or global
application-format admission scan. Consumers may store versions as ordinary
GraphValue properties, validate them in their model initializer and transform
them through consumer-authored migrations. No property name is automatically
interpreted as a version, including `appDataVersion`.

Graph still validates structure, identity, codecs, ownership, permissions and
budgets. Internal layout, attachment, codec and migration-journal protocol
versions remain library concerns. A failed consumer decoder is reported by typed
materialization; raw data access and non-materializing queries do not classify
application compatibility or silently filter unsupported records.

## Alpha and migration effects

Existing S01 (`GraphEvo.v2.schema.1`), current, prototype and M2a laboratory files
are refused before native loading. Do not relabel, erase or migrate them as an
opening side effect. M13 allows fresh alpha stores; mandatory v1 conversion and
future beta migration guarantees remain open. Keep the exact M2a/SM01–SM03
versioned fixtures as isolated historical experiments, not public activation.

Removing a local column does not remove an already deployed CloudKit field or
establish compatibility with old cloud data. No cloud reset or device mutation
is authorized by this change. A fresh, explicitly prepared Development fixture
must validate S02 sharing and independent recovery before closing that gate.
The previous S01 16-stage result remains evidence only for its original shape.

## Verification

Schema tests assert the exact two-column delta, deterministic model hashes,
identity indexes and unchanged detail entities. Fresh-store tests cover CRUD,
queries, files, integrity, leases and reopening. Historical-model tests include
S01 and same-shape/wrong-marker files, all public opening roles, and preservation
of durable source artifacts on refusal. Consumer-data tests cover mixed ordinary
application versions, typed decoder failure, generic access, query observation,
patch rollback, graph isolation and persistence across reopening.
