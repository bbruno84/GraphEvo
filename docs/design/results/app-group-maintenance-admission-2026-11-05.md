# App Group maintenance admission after an interrupted close

The [background expiration follow-up](apple-owner-background-expiration-2026-11-05.md)
observed process exit with a native close request still waiting for Apple
coordination. This laboratory increment evaluates a durable maintenance
admission check for one synthetic store. It uses the existing writer fence
to serialize registration and admission with native open and close.

## Scope in GraphEvo

| Path | Effect on the store |
| --- | --- |
| Application and widget reads, saves and record deletion | Use the open store and its transaction path. Record deletion changes graph contents through a transaction. |
| Participant leave and purge | Removes the local replica through the graph coordinator and runtime destroy. This is a current path that needs maintenance exclusion. Preserve its terminal access fence and pending purge if local destruction must wait. |
| Backup, local restore and v1 conversion | Copy to an empty destination, publish a verified backup at a new URL, or seed an isolated migration workspace. Preserve the destination checks and source snapshot protection. |
| Legacy local reset | Uses a separate legacy open registry and native destroy. Compatibility with the cooperating v2 experiment remains outside its scope. |

See the [local maintenance contract](../graphevo-2-local-maintenance.md)
and the [public sharing contract](../graphevo-2-public-sharing.md).

## Laboratory boundary

The test writes a separate claim for each native owner generation before
Core Data attaches. It removes only that owner's claim after the persistent
store count reaches zero. The maintenance probe uses the same writer fence,
checks the claims and keeps the fence through the Apple accessor. The probe
requests access without changing the store.

The claim directory belongs to a dedicated, stable fixture directory.
Replacement of that containing directory and access outside the cooperating
runtime are outside the test. Claims from interrupted owners require a
separate recovery policy. A later successful open and close clears only
the new owner's claim.

## macOS result

The probe refused maintenance with one or two independent owners attached.
After both closed, it obtained Apple access and held the writer fence until
its accessor completed. A concurrent open waited and then read the two
original records. When the runner killed a different owner with its close
request queued behind an Apple accessor, the writer fence was released
and the old claim remained. A new Core Data process read both records with
their exact IDs and passed graph integrity validation. After its clean
close, the maintenance probe still refused access and reported the old claim.

The first run found a directory creation error when a second owner opened
an existing claim directory. The corrected probe accepts the existing
directory after validating its type and rejecting symlinks. The corrected
run uses a fresh fixture. An independent repeat reproduced the result.

This result covers a package-only maintenance admission probe on macOS.
GraphEvo's production replica purge and actual store replacement remain
separate acceptance work. Clearing a claim safely after process loss is
still an open policy decision.

The private manifest for the independent repeat verifies 20 files.
SHA-256 `ca7d64f3fdd1656b41e2eca318b186710a71065ecbf4ed28f9ae2b7709fb4cdc`.
