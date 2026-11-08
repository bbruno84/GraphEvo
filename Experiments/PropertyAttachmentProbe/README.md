# Property and attachment device probe

This is an external signed-host replacement fixture, not a library target and
not an ordinary CI executable. Copy it over the disposable host library's
`Sources/GraphEvo/Experimental/GraphCloudActivationDeviceProbe.swift` and build
that host with the current repository sources. Keep the real application
entitlements and Development CloudKit container. Never replace a production app.
The fixture uses package-internal diagnostics to drive the public conversion,
connection, join and graph APIs deterministically.

Use a fresh run UUID and distinct owner/peer directories. Run `account` on each
device and privately transfer only the peer account fixture to the owner as
`recipient.private.json`. Run `seed` on the owner. It creates a stopped local v1
source, converts its 5 MiB + 1 byte Data property, adds raw and fixed-codec Codable
attachments plus a File, tests ordinary admission and publishes the authoritative
graph before inviting the pinned different account. Transfer only
`invitation.private.json` and `fixture.json` to the empty peer, then run `join`.
The latter independently verifies content before publishing a replacement.

Each successful stage retains its writer and CloudKit connection. Request
`<stage>.close.request` only after independent peer observation; require the
`<stage>.closed` receipt before replacing or restarting a successful writer.
Use the guarded launcher in `../PublicMirroredProbe/launch_probe.py` and require
its actual-process/active-scene acknowledgement as well as the stage report.
Never replay a consumed stage or copy a native store to make a fresh replica.

`resume-join` resumes an already accepted persisted invitation without another
acceptance or mutation. `peer-exchange` verifies the supplied fixture then
publishes the next revision. Transfer its fixture to the owner and use
`owner-exchange` to verify it and publish one further replacement. Transfer the
fixture back and use `peer-refresh` for a reopened read-only verification.
Each replacement preserves the oversized migrated value. Full record queries
must exceed a 4 KiB payload allowance while count and selected-property
projections succeed. Exact raw bytes, Codable values, collections and File
metadata/digest are checked on each replica. Keep account and invitation artifacts,
logs, stores and content external/private. This fixture establishes bounded
functional behavior, not production capacity or global convergence.
