# MF08 — repeatable internal store migrations

Status: package-only implementation integrates through
[PR #130](https://github.com/bbruno84/GraphEvo/pull/130), based directly on #129,
after local/device checks, review and full CI #335 on `3505fd5`. This structures the existing MF07 conversion without introducing
another manager, registry or automatic opening path.

## One definition per supported transition

`GraphStoreMigrationDefinition<Snapshot, Intent, Receipt>` describes one explicit
source-to-destination conversion. Its concrete types and synchronous adapters own:

- the exact physical source schema and supported read mode;
- bounded inspection and a semantic source fingerprint;
- the durable intent, backup artifact encoding and native completion receipt;
- conversion through the existing scoped adapter and receipt validation.

The runtime factory explicitly selects a `GraphStoreMigrationSource`, including
its scratch-backup validator. The runner refuses a definition whose source
schema/hashes/read mode or target schema do not match that configuration. There
is no source discovery, migration chain, global registration or consumer resolver.
Adapters are trusted library implementation: contexts cannot escape, save
independently, perform external writes or invoke arbitrary consumer bodies.

`GraphV1ConversionAdapter` supplies the first production definition. Its existing
package-only `convertLocalV1Store` entry point delegates to the common sequence.
V1 snapshot, intent, receipt and backup artifact formats remain unchanged. The
v1 aliases for errors, limits and results now name the shared types.

## Shared sequence under ContextManager

`migrateStore(using:request:limits:)` executes one stopped-source request:

1. Admit only one conversion per GraphID, resolve distinct source/target resources
   and acquire the existing runtime ownership claims.
2. Inspect the read-only source, independently checking its native UUID, and bind
   the request to its physical file identity and semantic fingerprint.
3. Recover a validated existing receipt before creating another backup or applying
   effects. Later ordinary target edits are preserved.
4. For an uncommitted operation, create/verify and durably pin the complete backup,
   then recheck source identity and contents.
5. Apply the concrete definition and validate its returned receipt inside **one
   destination transaction**, before save. Failure rolls back staged effects.
6. Close owned leases and release only this operation's backup pin. After native
   commit, cleanup failure is reported separately and cannot turn success into a
   failed conversion. Before commit, retain original and cleanup errors.

The request carries current URLs, GraphID, operation UUID, backup root and reason;
it is not Codable and no sandbox path is persisted. The caller retains stable
IDs and stops external writers. This does not rebind an already registered GraphID
from one file to another: bootstrap ownership and ordinary opening stay explicit.
The backup service still recognizes the native target and one explicitly selected
additional source. A source sharing the target's physical model does not replace
the normal native-backup validator.

Defaults remain 10,000 records, 100,000 native rows and 32 MiB logical payload,
with a 512 MiB hard payload ceiling. Intent artifacts are at most 16 KiB, reserved
single-component names at most 128 bytes, source fingerprints at most 4 KiB and
reasons at most 4 KiB. Concrete transitions retain their stricter mapping, receipt,
PH and structural bounds. Recovered receipts do not regenerate backup artifacts.

## Evidence and limits

A synthetic second definition uses an already-native S03 source, its own
snapshot/intent/receipt types, normal pinned reads and no v1 adapter. Tests cover
successful conversion, unchanged source, receipt recovery after later edits,
unsafe definitions, mismatched native identity, intent limits, invalid receipt
rollback/backup reuse and shared admission with progress for another graph.
This is test coverage for reuse, not a new supported production schema transition.

The common sequence currently supports bounded conversion into a distinct
native destination. It does not automatically implement in-place/staged Core Data
migration, transfer cloud checkpoints or compose future schema changes. Those
transitions need their own explicit data, recovery and compatibility contract.
S03, cloud/session/backup formats, default openers and public API remain unchanged.
Consumer application-data migrations remain a separate path. Historical source,
large-data/cloud activation, public bootstrap, physical interruption and scale
gates stay open. See [MF07](graphevo-2-v1-local-conversion.md) and the
[post-alpha checklist](graphevo-2-post-alpha-checklist.md).

[Results](results/store-migration-structure-2026-11-01.md) retain local checks,
review and two physical compatibility-recovery stages, without broadening MF07
acceptance.
