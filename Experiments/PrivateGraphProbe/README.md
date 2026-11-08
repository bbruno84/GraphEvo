# Ordinary private graph discovery device probe

Copy this external-only actor over the configured disposable authoritative host's
`Library/Sources/GraphEvo/Experimental/GraphCloudActivationDeviceProbe.swift`.
Build the host in Release against the exact current library sources with its
existing Development CloudKit entitlements. Neither this source nor the runner
belongs to an ordinary package/CI target. Keep signing, stores and logs external.

```sh
python3 Experiments/PrivateGraphProbe/run.py --device DEVICE-ID \
  --output /tmp/new-private-discovery-trial
```

Every trial creates an ordinary file-capable graph without v1 conversion,
including a note, cover, File and relationship. Binding publishes the existing
system descriptor. The probe retains the owner until direct server reads verify
all expected nodes/content, then closes the source session. A separate context,
session directory, catalogue and empty SQLite discover by the dedicated probe
zone prefix and recover through the new public reference API. It verifies bytes,
IDs, endpoints, zero outgoing feedback and reopen, then closes all owners.

This is real CloudKit on one physical device with independent sequential
sessions, not a two-device same-account certificate. No store is copied. Consumed
stages are never replayed. Failure preserves its phase/paths/process; investigate
before a new trial. The runner requires actual-process/active-scene launch and
final stage reports. It creates no invitation and touches only its fresh probe
zone. Definitive cleanup uses the later graph-deletion API, not ad-hoc zone removal.
