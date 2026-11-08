# GraphEvo 2 — consumer-owned application data

Status: maintainer decision M16 supersedes the former M2b.1 format contract.
The historical [M2b.1 result](results/m2b1-data-formats-2026-10-30.md) records what
was tested at that checkpoint, not the current public API.

Graph is a data-driven database with synchronization and sharing. The consumer
owns the meaning, compatibility and evolution of application values. There is
no GraphDataFormat, model registry, GraphRecord.dataVersion or resource-wide
application-format admission scan. [S02](graphevo-2-identity-schema.md) retains
native graph/node identity and removes the application-version column.

A consumer may store `appDataVersion` or another version property as an ordinary
GraphValue. Graph preserves, queries and synchronizes it without interpreting it.
Consumers may validate their representation in `init(graphRecord:)`; failures
propagate from typed fetch/query/patch. Raw access remains available. Count,
projection and aggregation evaluate requested graph values without constructing
the consumer model or certifying application semantics. Typed patches validate
the resulting model before editing; unknown properties remain preserved.

The migration manager executes consumer-authored transformations and provides
transaction, checkpoint and recovery machinery. Selection, compatibility rules
and semantic validation belong to the consumer; the manager must not recreate a
central format catalog. Whole-operation completion does not prove compatibility
of later imported records. Ongoing cloud processing, durable discovery and
convergence remain open migration work, under consumer-authored policies.

Native schema, value codec, attachment/control protocols and journal revisions
remain internal library responsibilities. Removing application versioning does
not remove structural checks, budgets, permissions, ownership exclusion,
mandatory v1 data migration or coordinated cloud cutover requirements.

## Property and attachment channels

The current coordinated profile uses scalars and recursively supported arrays
and string-keyed dictionaries in `GraphRecord.properties`. These values use the
library's version 3 property codec; collections remain in the application payload.
`Data` no longer conforms to `GraphPropertyValue`, and public `GraphValue` has
no binary or arbitrary encoded case. There is no generic Sequence fallback.

`GraphRecord.attachments` maps stable application field keys to
`GraphAttachmentValue`. Raw bytes use `init(data:)`; generic Codable values use
`init(codable:)` and the library's fixed sorted-key JSON codec. Models select
these channels explicitly in their existing `graphRecord(in:)` and
`init(graphRecord:)` mapping. Property and attachment key sets must be disjoint.
Patch edits preserve unnamed fields and reject ordinary attachment insertions
and replacements above 2 MiB of encoded bytes. Whole-record materialization
includes keyed bodies; count, projection and aggregation do not load them.

Mandatory v1 conversion preserves recoverable raw Data as keyed attachments,
including content above 2 MiB. It never guesses a raw Data value's application
format or silently turns it into a File. Known wrappers containing supported
collections unwrap to properties; mixed binary collections and opaque wrappers
preserve the complete original property in an attachment. Semantic conversion
remains consumer-owned. See [the storage contract](graphevo-2-property-attachments.md).
