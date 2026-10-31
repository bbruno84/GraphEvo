# T08 sharing lifecycle device protocol

Export a committed runtime into a new external signed host with `prepare_demo.py`.
Use a new run UUID and Development zones/stores, without container reset or store
copying. Protect identity and invitation handoffs. Reserve every stage before
effects and never replay a `.started` mutation. A launch receipt is not a stage
result. Keep the owner alive until independent participant observation.

Sequence on different-account iPad owner / iPhone XR peer:

1. Peer `identity`; transport identity to owner; owner `seed`; transport invitations.
2. Peer `accept`; verify A read-write/entity/file, C read-only and private B isolation.
3. Peer `pending` leaves two A consumer edits unpublished; owner `downgrade`;
   peer `read-only` verifies retained backlog, refused writes and progressing imports.
4. Owner `revoke`; peer `revoke-start` writes `.ready` at the Debug barrier after
   durable removal intent and application blocking, before store destruction.
   Terminate that process deliberately. The interrupted stage has checkpoint
   evidence, not a fabricated completed report.
5. Peer `recover-purge` registers the current old A URL, completes local removal
   after restart and checks C. No application data opener is used for purging A.
6. Owner `reinvite`; transport the fresh invitation bundle; peer `rejoin` imports
   into A-Rejoined.sqlite, rejects the discarded pending record and preserves C.
7. Peer `leave`; owner `stop` ends C sharing without removing private data.
8. Peer `stop-all` pauses C and activates foreground orchestration; the control
   worker must detect and purge it without manual refresh/fetch/apply.
9. Owner `audit` verifies complete A/B/C cloud/local inventories and file content.
10. After rebuilding with a later correction, optional read-only `final-audit`
    (owner) and `removed-state` (peer) inspect the same fixture without replaying
    any mutation. Record their separate source pins; they do not extend the
    original mutation matrix to the later source.

The bridge uses `--sharing-lifecycle STAGE RUN owner|peer` with the acknowledged
PublicMirroredProbe launcher. Full inventories and reports stay external. This
bounded protocol does not certify background delivery, cross-process destruction,
distributed owner command ordering, or deletion of consumer exports/backups.
