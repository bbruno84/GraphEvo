# App Group synchronized access and owner recovery probes

Date: 2026-11-06. Scope: the second public App Group increment, based on
integrated `b6886576` (#180). The probes use synthetic resources and leave the
library runtime and acceptance checkboxes unchanged.

## Direct CloudKit access verification

A temporary signed iOS app used the existing GraphCKDemo Development container
on a tenth-generation iPad and an iPhone XR with different verified accounts.
The probe called `CKContainer` and `CKDatabase` directly. It created a fresh
private zone, verified that the owner's account could fetch it, then created
one zone-wide private share. On the XR, the participant accepted the share
and fetched its record from the shared database. The iPad reduced the
participant's permission, and a fresh process on the XR fetched the updated
share. No sync engine or GraphEvo transport was constructed.

| Observation | Result |
| --- | --- |
| Owner private zone fetch | Expected zone returned in 313 ms |
| Participant after acceptance | Accepted and `readWrite`, share fetch 388 ms |
| Participant after downgrade | Accepted and `readOnly`, share fetch 387 ms |
| Cold downgrade inspection | 798 ms including account and invitation metadata lookup |

These are single samples on the tested devices and network. The first setup
attempt stopped on a CoreDevice launch error and cleaned its zone. The passing
attempt used a different zone, deleted it after the test and reinstalled the
previous H02 build on both devices.

The signed secondary was a standalone app process. The available App Group
widget profiles grant App Group access and lack the CloudKit container
entitlement. Verification inside a signed widget and its execution budget
remain separate. This probe supplies direct account and permission evidence
for an appropriately entitled process. Publication of a local App Group
commit through the primary's Persistent History path remains a separate check.

## Exact offline owner recovery

A macOS supervisor launched a child using the public primary App Group path
and retained its process handle. The child created a fresh S04 graph,
committed one record and kept the native owner attached. An independent
process requested a Foundation deletion grant. Foundation refused the live
presenter. After SIGKILL and observed process exit, the same grant succeeded
and the original durable registration was still present.

The diagnostic used that grant to validate the graph and native store UUID and
to check one exact owner generation. A wrong generation and a wrong native
store UUID both preserved the registration byte for byte. With the exact
identities and supervised exit, the diagnostic removed the single registration
and the reopened public graph returned the original record with its exact ID.
No SQLite file was deleted.

The supervisor's observed child exit supplied the proof for this control.
A grant after cold reopen or a retained registration alone does not establish
that proof for arbitrary production processes. Production recovery authority
and resumption of an already started destructive operation remain open.
