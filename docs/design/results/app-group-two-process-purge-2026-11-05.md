# Participant replica purge across App Group processes

A signed app and its widget App Intent used the same disposable participant
replica on a physical iPad running iPadOS 27.0. The private build was based on
`e8c6d269` with laboratory changes, including a candidate existing-store guard.
The app used the actual `GraphContextManager.leaveCloudShare` path with an
injected CloudKit adapter. The test retained the runtime writer and owner
locks. The widget opened the same SQLite store through `StoreRegistry` and
read the exact generation-keyed record through a package control read.

## Termination with a replica attached

1. While the widget held the native store open, the app requested leave.
   The runtime refused destruction with `resourceReserved` before the
   laboratory destruction hook ran. The replica remained on disk and
   the membership stayed in `purging`.
2. The Mac started observing termination of the exact widget PID before
   sending SIGKILL. It matched the resulting exit record to the fixture,
   graph and owner generation published by the widget. The original app
   also exited normally while backgrounded.
3. A fresh app process loaded the existing membership. Registration and
   explicit leave retry reached the destruction hook, which refused both
   calls while the widget registration remained unreleased. The replica
   stayed on disk and the original leave intent stayed pending.
4. The supervisor published release for the exact widget registration.
   A further leave retry removed the SQLite, WAL and SHM of the replica.
   The membership reached `removed` with reason `left` and no pending leave.
   The neighboring SQLite file stayed byte-identical and still returned its
   control row `742` through a read-only connection.

The independent evidence manifest for this fixture has SHA-256
`8ed2ce9230b8d52534e09a211c4662c92b6819664b73e88595365d262b2145bb`.
The supervisor killed the widget with the store attached in this variant.

## Termination during native close

A fresh fixture repeated the live refusal. The app then signaled the widget
to close its handle. The widget called `handle.close()` and published its
PID, graph ID and generation from the runtime's `beforeDetach` hook, while
the native store was still attached. The supervisor observed that checkpoint
and started monitoring the exact PID before sending SIGKILL.

The initial app also exited normally. The new app process loaded the same
pending leave and reached the destruction gate twice. Registration and the
explicit leave retry both returned `busy` while the original registration
remained unreleased. SQLite, WAL and SHM were all present at that point.
After the matched release, the next leave retry reached `removed` and
cleared the pending intent. The three replica artifacts disappeared, and
the neighboring SQLite file was byte-identical across the snapshots and
readable with the expected control row.

The independent verifier matched the launch, signal and termination records
to the App Group artifacts, checked event order and compared the durable
membership identity and state before and after release. The evidence
manifest for this fixture has SHA-256
`a83609804e749511bffec41b272f8fecebff94d2818e005f6c9a7867f7bb04e1`.

## Scope

The Mac's device supervisor supplied exit evidence. The durable refusal
and exact release gate were laboratory hooks. A participant read via the
public API in a separate widget context was denied without verified account
access. The control read confirms native attachment and the exact graph
record. A second standalone app could not sign with the available
provisioning profile, so the signed widget supplied the second process.

The production App Group recovery authority, Apple replacement owner
protocol, public widget account access and live CloudKit leave remain
separate work. Without proof that the exact prior owner exited, cleanup
stays pending. The [single-process device result](app-group-participant-purge-device-2026-11-05.md)
covers iPhone XR separately. The physical builds use the private opening
guard candidate. The reviewed #169 fix is covered by the separate
integration baseline at `e03f99d3`, which passed 24 sharing lifecycle tests
and 13 process-lock tests on macOS.
