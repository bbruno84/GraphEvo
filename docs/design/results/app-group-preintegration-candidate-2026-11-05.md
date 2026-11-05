# App Group presence coordination before integration

The private candidate is preserved at `b78e7203`, based on `4bb615e1`.
It carries #169's existing-store admission check. Marked synthetic stores use
finite Apple file coordination and a durable native owner registration.
The existing writer fence spans admission
and native work. Each owner publishes its registration before attachment and
clears it after the native coordinator has zero stores. The participant test
calls the real local leave and destruction path. It uses an injected CloudKit
adapter and a laboratory supervisor to verify process exit.

## Purge and restart

Three fresh fixtures passed on physical iPadOS 27.0. The widget independently
opened and read the replica in each fixture. Native destruction refused the
request with a live widget. In one run the widget process exited with code zero
after reaching the native close checkpoint. In another, the supervisor observed
that checkpoint and confirmed SIGKILL on the exact widget process. Neither
trace contains a successful guest detach. The app also exited in both cases.

The new app refused destruction while either original registration remained.
Matching supervisor proofs recovered the two registrations. The second use of
a consumed proof was refused. The actual retry acquired Apple access for
destruction and cleanup, removed the target SQLite, WAL and SHM and settled
the membership as `removed`. The neighboring SQLite file remained readable.
In the third fixture the widget detached normally and cleared its own
registration. The same app process completed the purge without supervisor
release. No fixture used the lifetime owners lock.

Two macOS repetitions confirmed the ordering of an independent opener queued
behind the real purge. The opener waited on the writer fence, then received
`missingStore` after the native deletion and cleanup. It registered no owner
and attached no store. Both repetitions refused a proof with the wrong store ID
without clearing any registration. The neighboring SQLite file was byte-identical.
A separate macOS fault after native destroy and before artifact cleanup
verified the retry while the destroying process survived.

A controlled macOS termination in the same window left one registration and
SQLite placeholders. Cold registration refused the old native identity and
kept the membership in `purging`. The SQLite and WAL bytes and the neighboring
database were unchanged. The SHM file stayed present and its bytes changed
during the cold metadata read. Completing cleanup from this checkpoint would
require durable evidence of which artifacts the interrupted destroy owned.

## Lifecycle, sync and costs

The iOS 18.5 simulator and physical iPad each completed 30 Home, widget write
and app reopen cycles. The verifier checked distinct processes, registration
before native attachment, release after detach, old handle refusal and exact
readback of 32 records including two 4 MiB values. In three iPad cycles the
background notification arrived after the widget's opening grant. The host
had already become inactive and detached before the widget attached in every
cycle. The signed iPad app ran through Device Hub after the XCTest runner
stopped while enabling UI automation. An earlier physical run with no widget
writes remains a host-only control.

Nine additional iPad fixtures cover three failures after native attachment,
three during initialization, and three during native close. Each faulted owner
was terminated under observation. A new process read the exact baseline and
closed its own store while preserving the single orphan registration. For each
failure mode, a background fixture exercised both deletion and replacement
admission with the faulted owner alive and again after its exit. Every probe
refused while the original registration remained.

In a separate failed-close run, UIKit delivered expiration 26.406 seconds
after the background notification and 31.336 seconds after the task began.
Deletion and replacement probes were refused before and after expiration.
The supervisor later terminated the original process and a cold readback
matched the baseline. With budget still available, a close submitted behind
a widget Apple accessor waited 12.216 seconds for its grant. The owner then
detached, removed its registration and ended the task in that order.

Another fixture ended the task while close was queued, 20.649 milliseconds
after close submission and before the widget returned its accessor. The
original app exited with no recorded closing grant or detach. Both maintenance
probes still refused and a cold read recovered the exact baseline with the
orphan registration retained. An earlier attempt to signal the app while queued
finished detaching before the signal took effect. That run is inconclusive for
interruption and is retained separately.

Marked macOS and iOS 18.5 tests passed cancellation while waiting for an Apple
grant, cancellation during file preparation, rollback before save and retention
of a save already committed. Fresh readback verified the exact two 4 MiB
attachments. The candidate routes coordinated local attachment imports
directly through the typed transaction. The old import entry point otherwise
queries the legacy mirroring container through a privileged native operation,
which the marked runtime refuses.

In separate macOS processes, SIGKILL before the native save left the counter
and new record uncommitted. SIGKILL after the native save retained the counter
increment and the exact new record once. A fresh process read each store and
released its own registration, leaving the terminated writer's registration
in place.

The marked macOS sync composition drains an admitted send and read before close,
preserves the pending edit and inbox across reopen, and ignores retired callbacks.
Temporary account unavailability preserves the engine state. An account change
clears the SDK engine serialization under the existing account contract and
preserves durable graph work. The session and backup catalog contention checks
verified lease release. The focused checks also passed 129 functions on macOS
and 130 on the iOS 18.5 simulator.

Three matched repetitions for each mode and process count verified 900
committed transactions across M2 and the candidate. Each process performed 50
counter updates and inserts with a retained native owner. Median measurements
from the second comparison batch are in milliseconds.

| Mode | Processes | Batch | Open per owner | Close per owner | Apple wait per write | Body | Save |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| M2 | 1 | 614.42 | 21.24 | 4.59 | 1.54 | 7.49 | 0.92 |
| Candidate | 1 | 606.60 | 511.82 | 3.38 | 1.21 | 6.44 | 0.96 |
| M2 | 2 | 1,974.03 | 20.84 | 3.63 | 1.62 | 10.23 | 0.99 |
| Candidate | 2 | 1,855.26 | 264.29 | 3.12 | 1.21 | 8.63 | 0.97 |

The one-process candidate trace puts about half a second of immediate reopen
time between submission and Apple's opening grant. The workload matches across
the two modes. The historical M2 harness uses its direct native adapter and the
candidate uses GraphContext, so the table measures both complete paths.

## Evidence and integration gate

The iPad purge manifest SHA-256 is
`028d9f7dbab7b67f7cc2d522cad2a4564397c3de2d62cc962681f23b9ee801a0`.
The simulator cycle manifest SHA-256 is
`bda1eeb7f6bd4bdd4cc7e2faefbdbfe3a690529fad18b951293daa880f3bc30d`.
The physical iPad cycle manifest SHA-256 is
`f7fa9f0c8491d7f63eac8c7405b3785ee0ba3ecbe899a00b7f96472e06e48ede`.
The nine physical fault fixtures have manifest SHA-256
`64f8f310aedb4a74e30ca0952818471d25c9ddf21529a945535f9888dd808ba6`.
The physical budget and queued close manifest SHA-256 is
`2708e7afd1709d5b6ff22b1f8f04831088df44d51351733d4ac0d781111d8f3a`.
The macOS trace and benchmark manifest SHA-256 is
`393e2dc30c6ce75d81dc24898391b7267946598bf4caeca8a67cf315a7bbc5d3`.

The scoped pre-integration test plan passed on the private candidate. The
supervisor proof remains a laboratory capability. Cleanup stays pending
without proof for each abandoned registration. The cold crash between
native destruction and artifact cleanup also stays pending. Physical iPhone
XR validation, real CloudKit and the public App Group roles are separate
pre-beta work.
