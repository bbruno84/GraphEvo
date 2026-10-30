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
