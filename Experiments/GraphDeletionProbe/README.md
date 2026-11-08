# Graph deletion probes

The macOS executable is Debug-only and laboratory-only (`GRAPHEVO_BUILD_LABS=1`). It terminates
its own fresh fixture with SIGKILL at three native destruction boundaries, then
moves each stopped fixture container and uses a separate process to resume the
exact operation, checking File cleanup and preservation of the consumer source. A fourth case holds the
store open in an independent process, verifies deferred destruction and normal
owner detachment, releases the holder and resumes cleanup.

```sh
GRAPHEVO_BUILD_LABS=1 swift build --product GraphDeletionProbe
python3 Experiments/GraphDeletionProbe/run.py --binary /absolute/path/to/GraphDeletionProbe --output /new/external/evidence
```

`run_device.py` uses the signed external host and the guarded launcher from the
private discovery probe. Build that host with this directory's
`GraphCloudActivationDeviceProbe.swift` replacing only its external probe actor.
It publishes a fresh ordinary graph, independently verifies server content,
recovers it, deletes the recovered owner graph and verifies that the returning
original replica cannot recreate the zone. A restarted session resumes completed
removal. Every trial uses a new UUID and output directory; consumed mutations are
not replayed. Device stores, routes, account identities and generated evidence
stay outside Git. This is a same-device sequential-session CloudKit test, not
cross-device convergence or a shared participant acceptance certificate.
