# MF02 review and correction — 2026-11-01

Reviewed head: `69bde89`, package implementation `3e509f0`, PR #121.
Scope: `.geb` header/framing, bounded compression/extraction, native validation,
legacy paths, retention, owned cancellation, capture admission and transfer.

## P2 — nested legacy import altered the source before rejecting it

`GraphBackupManager.importBackup(at:in:)` created the collection root before
calling export's containment preflight. When the source was a supported legacy
directory and the requested collection was `<source>/Nested/Collection`, the
operation threw `invalidDestination` but left `Nested` in the immutable backup.
Subsequent verification failed with `invalidBackup`.

A committed parameterized regression reproduces this through direct and
symlink-aliased paths. Both fail on the reviewed source: source directory contents
change, the new directory remains and verification fails. No production/source
graph is used; each case creates a fresh isolated fixture.

Correction `8bf64b0` delegates destination creation entirely to export's existing
preflight. Import reads the manifest, forms the destination and calls export;
only the validated path can create the collection. Regression assertions compare
the original inventory, reject the new child and successfully reverify the source.

## Corrective re-review and checks

The corrected wrapper introduces no alternate mutation path. Existing missing
parents/aliases, duplicate/occupied targets and URI validation flow through the
same export admission before creation. The regression is retained in the package
suite. No other blocker was identified in this bounded review, including stream
end/input accounting, declared versus actual expansion, regular-file extraction,
temporary-stage cleanup, pause ownership and graph/backup separation.

Corrected source passes 786 macOS functions (331 legacy, 356 store, 76 runtime,
23 model), 431 selected iOS 18.5 Simulator functions/510 invocations, Release
package build, Swift 6 ModelConsumer, manifest and diff checks. The simulator
summary reports no failures, skips or runtime warnings. The remote checkpoint is
recorded in development status and the PR. Original compression and bidirectional native
macOS/iOS Simulator reports retain their implementation pin: this correction
does not modify the container/codec or claim new physical/cloud evidence.

The maintainer authorized review/corrections → CI → merge on success. The remote
checkpoint follows corrective review; no failed local reproducer is presented as
successful acceptance. Power-loss, physical/production scale and independent
cross-user graph activation remain open.
