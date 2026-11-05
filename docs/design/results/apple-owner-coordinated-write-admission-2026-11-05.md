# Apple coordinated writes and foreground ownership admission

The private Q experiment extends the [native presenter baseline](apple-owner-runtime-lifecycle-2026-11-05.md)
for one selected S04 SQLite store in a dedicated fixture directory on macOS.
The native owner uses its own presenter when creating each finite Foundation
write request. The synchronous accessor encompasses the Core Data transaction,
save or rollback, and context cleanup. Completion resumes the caller after the
accessor returns. The current writer fence is acquired first. The presence
fence stays held until native detach. The peer probes acquire Apple access only.
A peer that holds Apple access while requesting the writer fence would reverse
the acquisition order and can deadlock with Q.

An independent process holds an Apple write accessor. A GraphEvo transaction
submits and waits even after it has acquired the existing writer lock. After
grant, a peer submitted during the transaction's body obtains access only
after the native save settles. A second successful write and cold reopening
recover the two exact committed records. Independent deletion and replacement
probes receive the presenter's refusal while the owner is live.

Cancellation while waiting returns before the blocking peer releases its
accessor, and the waiting mutation body never runs. Cancellation after native
mutation rolls back before a peer can obtain access. The two cancelled records
are absent from the cold readback. This path covers `StoreResources.transaction`.
Prepared control transactions, other native operations, opening and detachment
have separate coordination requirements.

The composed test puts an application-owned admission boundary around one
real public graph and connection. Starting closure rejects new reads, writes
and observation requests through that boundary. A send already admitted by
GraphEvo settles, and a previously admitted application read still completes.
The boundary cancels its tracked observations, closes transport and waits for
native detach. Cancelling the caller waiting for shutdown leaves the drain
running. A resume requested during closure waits for that generation to close
and publishes a fresh token. The previous token and closed graph handle refuse
access. This harness controls access through its own boundary for one graph.

The reopened graph retains the newer pending edit and the unapplied remote
record. The fresh public observation sees the applied record. Late state,
receipt, inbox and account callbacks from the retained retired session leave
the new session state intact. The observation control passed with the presenter
alone. The composed run passed the 11-test pause suite, with 15 traced Apple
write requests across the two graph generations. Each trace shows submission,
grant, native settlement and completion within its attached owner's lifetime.

This is a laboratory result with injected cloud transport and the existing
runtime fences. The next acceptance work includes ownership while removing
the existing presence fence, coverage of the other native write paths and
physical iOS app/widget lifecycle checks.

Independent review verified 26 entries in the native write probe and the
composed lifecycle evidence and ordering. Private write report SHA-256
`d841c3d6a8004e4c29a4fd82234ac267d394557c8ed47fdd132c43015ac30800`.
Private write manifest SHA-256
`d9075871e670c539abaa7e0efa59bd43d050489bc7b4824d1037c79462d0ccde`.
Private composed evidence manifest SHA-256
`057ee74bc63f0c00d6665ee043fba4eba37a764fd9f275ac926bd8da494bb527`.
