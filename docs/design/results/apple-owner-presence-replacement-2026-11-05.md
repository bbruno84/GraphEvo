# Apple coordination in place of the presence lock

The private R experiment extends [Q](apple-owner-coordinated-write-admission-2026-11-05.md)
on macOS using synthetic S04 stores in dedicated directories. The laboratory
build requires an exact path, explicit opt-in and a fixture marker. A matching
process uses finite Foundation write access for native load and last detach.
It registers the directory presenter inside the opening grant before native
load and unregisters it inside the closing grant after the coordinator has
zero stores. Ordinary writes use the Q accessor. All three paths acquire the
existing writer fence before requesting Apple access. The lifetime
`owners` flock is absent.

Two independent GraphEvo processes opened and wrote the same fixture. A
separate process holding Apple access delayed both the second open and the
first owner's last detach while the GraphEvo writer fence was held. Cold
reopening found the two expected note IDs and values and passed graph integrity
validation. An independent repeat on a fresh fixture reproduced the results.
Delete and replacement dry runs were refused with both owners live, with one
remaining owner, and again after a fresh open. Both dry runs obtained access
after the last close. No probe changed or removed files.

Delete and replacement requests submitted during an intentionally held opening
grant, before presenter registration, were refused after native attachment.
An injected failure inside the close grant retained the native store and
presenter. Both maintenance requests were refused during quarantine and
obtained dry-run access after controlled process termination. The marked
fixture also refused opening without the opt-in and refused GraphEvo's
destroy request before invalidating the live handle.

The separate composition passed all 11 macOS pause tests. The instrumented
lifecycle test used the public graph, connection and observation APIs with
injected transport. The old generation drained admitted work, then detached
before the new generation opened. The new generation recovered the pending
edit and durable inbox, ignored the retired session's callbacks, and applied
the incoming record to the fresh observation. Its trace verifies 15 ordinary
write grants and four native transition grants across two generations. The
fixture checks found a writer sidecar and no presence sidecar at both opens
and after the final close.

The result passes the bounded macOS experiment. PA02 remains open. Actual
destructive maintenance and privileged paths are excluded in the fixture.
Prepared control work still uses the existing writer fence outside Apple
access. Compatibility with older uncoordinated binaries, partial-load
quarantine and physical App Group suspension with this R path require separate
evidence. The transport used in the lifecycle test was injected.

The private native evidence verifier checked 136 files. Native evidence
manifest SHA-256
`e4f3133be7e27f33e4d96db28f3b8be2d8efc9c5f1f5a9979978ab4e6a6f5d58`.
Private composed evidence manifest SHA-256
`2c3d9d8cf1846990194258b47915a35283a358c49b1ad4d50da21345b149b907`.
