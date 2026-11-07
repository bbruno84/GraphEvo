# File synchronization review — 2026-11-07

Scope: PR #190 against `codex/graphevo-2`, including transport, schema-copy
history, incoming/outgoing ownership, permission enforcement and destruction.
The physical checkpoints retain their actual earlier source/runtime scope.
No remote CI checkpoint or merge is part of this review request.

## Corrected findings

- Read-only participant reclamation used the consumer mutation boundary and
  rejected removal of retired local content. Reclamation now uses the existing
  runtime control transaction/writer grant. A regression imports a replacement
  into a read-only replica, reclaims only the retired revision, preserves the
  current content and permission, and verifies no outgoing work was created.
- Terminal replica purge destroyed SQLite without removing the new File
  directory or frozen outgoing contents. S05 supplies a schema-owned cleanup
  callback under exact native identity and exclusive Apple deletion admission,
  before SQLite destruction. It includes current/retired revisions and abandoned
  preparations. Durable session purge also releases discarded incoming assets.
  Tests cover ordinary success, refusal before content removal, a cleanup failure
  after permanent content removal followed by retry, and interruption after
  removing the last spool marker. Consumer exports and a different store
  generation's directory survive. Failures retain the purging state.

These corrections reuse the existing coordination and registration lifecycle.
The native model, File schema identifier and public signatures are unchanged.

## Roadmap decision

The integration baseline is #189 (`65818685`); #190 remains pending integration.
Alpha keeps eager File download with synchronization and scoped local URL
access. On-demand download/progress is an optional future evolution, not a
beta gate. Measured midstream network interruption, broader fault/backoff
acceptance and representative large-file time/memory/disk measurements remain
open. The 50 GB native transport ceiling is distinct from verified capacity.

## Final verification

- macOS v2 profile: 631 store, 91 runtime and 30 model tests passed (752 total).
  The established profile excludes `twoThousandRecordNativeSortFitsTheUnchangedStepBudget`;
  this exclusion is not counted as passing capacity evidence.
- Final iOS simulator subset: 61 tests across sharing lifecycle, File transport,
  the durable spool and session handling passed. The earlier local-file and
  automatic-scheduler subsets also passed.
- Manifest validation and `git diff --check` passed.
- No unresolved GitHub review threads were present when inspected.

Both identified lifecycle findings are corrected. No further blocking finding
remains in this review. Physical cross-account/SIGKILL evidence is retained
separately; the review's reclamation/purge corrections have local macOS and
iOS simulator evidence, not a new signed-device checkpoint.
