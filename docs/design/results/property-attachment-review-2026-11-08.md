# Property and attachment pre-merge review — 2026-11-08

PR: [#191](https://github.com/bbruno84/GraphEvo/pull/191), targeting
`codex/graphevo-2`. Reviewed implementation: `9ecd920f`; subsequent integration
notes change documentation only. The complete increment includes the value
contract and the publication-cost correction. No unresolved actionable finding
was identified in this review; no source correction was required.

## Reviewed boundaries

- Public properties contain scalars and supported recursive collections.
  Data and generic Codable enter through keyed attachments; the removed binary
  property APIs fail compilation at their intended boundary.
- Ordinary inserts and replacements enforce 2 MiB after encoding before edits.
  Migrated/imported admission is package-internal. Descriptive origin metadata
  cannot authorize an oversized ordinary write. Scalar edits preserve an
  existing oversized migrated body.
- V1 native conversion preserves owner/key/bytes and source property versions,
  checks the canonical source fingerprint and includes extracted attachment IDs
  in the initial synchronization baseline. Opaque binary collections preserve
  their whole archive rather than guessing consumer meaning.
- Fresh S06/S07 profiles retain historical model factories and refuse old alpha
  files and operational formats unchanged. File metadata and immutable content
  retain their separate lifecycle.
- Full materialization charges attachment bodies. Metadata and property-only
  projections avoid faulting bodies. Native attachment metadata and byte count/
  digest checks remain separate from content availability claims.
- Incoming CKAsset URLs are frozen within their callback lifetime; orphan
  attachments remain durable until their owner is available. Oversized migrated
  content can advance as a singleton outside the ordinary preparation window.
- S06/S07 finite read grants start before pinning SQL and last through copying
  external bytes and resetting the context. Lifetime presentation watches the
  stable registration directory; operations, copy and claim cleanup use the
  original coordination root. Parent deletion still consults live presenters.
  Cancellation and same-resource reentry protection remain.

## Verification retained at the reviewed implementation

- 773 macOS v2 tests: 646 store, 94 runtime and 33 model; all 331 legacy tests.
- 197 affected iOS 18.5 Simulator tests, without failures or skips.
- Both Swift 6 consumers, including independent macOS processes; three public
  negative compile fixtures, repeated during this review.
- Real Development CloudKit private/shared iPad/XR exchange and replacement;
  corrected signed Release build reopens and verifies both existing replicas.
- Complete synthetic publication/recovery: 12.83 seconds Debug and 12.59/12.66
  seconds Release, preserving assertions and the original two-minute guard.
  Final focused repeat passes six capacity/property tests in 12.74 seconds;
  the three presenter scope tests also pass.
- Manifest validation, whole-PR diff whitespace checks and diagnostic timing
  patch applicability pass. No generated stores, account artifacts or logs enter Git.

See the [contract acceptance](property-attachment-contract-2026-11-08.md) and
[cost investigation](initial-publication-cost-2026-11-08.md) for scope and limits.
The local synthetic timing does not measure Apple's network or device throughput.
Production source coverage, wider distributed conflicts, device memory/capacity
and broader PA05/PA06/PA08 acceptance remain open.

The maintainer authorized review, roadmap update and merge. Under the current
[alpha checkpoint policy](../graphevo-2-ci-checkpoints.md), this increment uses
reviewed affected local evidence; no additional hosted checkpoint is requested.
The last full hosted checkpoint remains the one recorded in development status.
