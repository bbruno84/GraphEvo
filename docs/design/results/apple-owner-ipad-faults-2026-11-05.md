# Apple owner fault continuation on iPad

2026-11-05. The private CoordinationLab continuation exercises the iPad fault
cases left open in the [N report](apple-owner-priority-tests-2026-11-04.md), using
the same signed laboratory build and seven fresh synthetic stores. The stores
use the S04 Graph adapters and contain the original four records, serialized
application values and two 4 MiB attachments.

| Injected fault | Observed outcome on iPadOS 27.0 |
| --- | --- |
| Native close fails | After `didEnterBackground`, the independent widget's deletion coordination request receives `M.NativeOwnerActive.1` from the retained presenter. The host records that it still holds the claim. The console then reports signal 9. A subsequent deletion coordination request is admitted and a fresh process reads the original store. |
| Opening fails after adding the native store | The widget receives the same refusal in background while the partial owner remains attached. The console then reports signal 9. The probe is admitted after process exit and a fresh process reads the original store. |
| Opening fails during initialization | The background refusal, signal 9, subsequent admission and exact cold readback repeat with this injection point. |
| Controlled SIGTERM before native save | The host reaches the before-save marker and enters background. Cold readback returns counter 0 and the four original IDs. |
| Controlled SIGTERM after native save | The host reaches the after-save marker and enters background. Cold readback returns counter 1 and exactly one new ID. |

The deletion requests are dry runs that exercise admission without deleting
files. The close fault also has two earlier trials. In the delayed trial, the
first probe is granted and the next process snapshot already lacks the host.
The faster trial captures a refusal before the host disappears and a grant
afterward. The console trial captures the signal and the refusal on the same
fixture. The cause of signal 9 remains undiagnosed.

The pre-save and post-save tests use deliberate SIGTERM injections while the
coordinated operation is still open. Each cold readback checks the full ID set,
structured application values and exact byte counts and digests of both
attachments. The post-save result contains one committed change without replay.

Both controlled interruptions leave a `Prepared-*` directory containing two
4 MiB temporary files. The read-only recovery preserves these files as evidence.
Store integrity passes and temporary-file cleanup after process death fails in
the laboratory. A recovery policy must distinguish abandoned files from work
owned by a live peer before removing anything.

The observed iPad fault paths satisfy the protocol's data protection and recovery
criterion for the store. Production adoption remains **NO GO** pending temporary
file recovery, XR physical coverage and coupling of the real synchronization and
public observation lifecycle. The original 30 successful normal-path iPad cycles
remain separate evidence.

Independent review reran the verifier over 284 manifest entries and checked the
original N hashes, exact recovered IDs, attachment digests and retained packet
sizes. The three console trials record widget refusal 128–168 ms after the
background notification. Raw stores and traces remain in the private laboratory.

Private continuation report SHA-256
`e7190f0fe80d511e4d67a5adde82606e19f737226666a397d88e571597dd4b31`.
Private continuation manifest SHA-256
`0b8a475e04a9b0c442748c6a055bcd0563e0e4f709dfb3d27fc44511adc18eea`.
