# Physical device capacity and cost — S06/S07

This external signed-host lab targets the integrated `30c01ab6` implementation.
It changes no runtime behavior, schema, budget or public API. Its two Swift files
are copied only into a disposable signed host: `GraphCloudActivationDeviceProbe.swift`
into `Sources/GraphEvo/Experimental`, and `CapacityTransport.swift` into
`Sources/GraphEvoStore/Experimental`. Neither belongs to an ordinary package or CI
target. Use the existing authoritative host controller and guarded launch receipts.
Build Release, iOS 17 minimum, with the real development host entitlements.
Keep generated files, signing data, reports and source stores outside Git.

Prepare from an existing configured disposable authoritative host (not the demo
source checkout), then build the resulting Xcode project:

```sh
python3 Experiments/DeviceCapacity/prepare.py --host /tmp/configured-authoritative-host \
  --output /tmp/new-device-capacity-host
xcodebuild build -project /tmp/new-device-capacity-host/Host/GraphEvoDemo.xcodeproj \
  -scheme GraphEvoDemo -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/new-device-capacity-host/Build -allowProvisioningUpdates \
  IPHONEOS_DEPLOYMENT_TARGET=17.0
```

The preparer copies shipping sources from the current committed checkout and
records its exact revision externally. The measured baseline is `30c01ab6`;
when using a different baseline, update the probe's environment marker and
record the change in the report. Install the signed app using `devicectl` before
running a stage. Preserve any unrelated live owner before replacing a build.

## Matrix and assertions

| Stage | Data | Required checks |
|---|---|---|
| strings | 36 × 720,000-byte scalar strings, small converted source | Complete synthetic activation and recovery into empty SQLite; exact values, no outgoing feedback or extra sends |
| binaries | 32 × 2 MiB keyed attachments; 25 and 128 MiB Files | Exact bytes, 2 MiB + 1 rejection before scalar edit, count/projection success at 4 KiB, full-query budget refusal plus admitted 64 MiB materialization, replacement, File digest and deletion/reclamation |
| delete-control | Empty File with zero versus 32 unrelated 2 MiB attachments | Same deletion API, fresh reopened stores; unrelated owners survive |
| representative | A stopped complete MyHomeBills v1 copy | Native conversion with backup, 1,577 mapped source nodes, all owner records materialized separately, extracted attachment counts/bytes, integrity, reopen, metadata listing, original source artifact digests unchanged |

Every invocation allocates a fresh run UUID and refuses a consumed stage. Repeat
strings and representative stages with fresh fixtures; binary reads repeat three
times within the same process and are explicitly warm-cache observations. The
representative source's binary meanings are not inferred. No consumer content is
converted to File; doing so requires a separately agreed consumer mapping.

The synthetic service exercises native codecs, spool, journal, receipts and
independent SQLite recovery **on the physical device**, without Apple's network.
Do not report this as CloudKit bandwidth. Local binaries/representative stages
also perform no cloud publication. Existing real CloudKit functional evidence
retains its original independent scope.

## Measurement

Each measured phase records monotonic wall time and a physical-footprint sample
every 25 ms using `TASK_VM_INFO`, plus samples at entry/exit, before/after process
footprint and thermal state. Samples are not an instantaneous peak or a memory
limit certificate. Memory includes the host, Foundation/Core Data and the
synthetic service when active; phase deltas are not allocation attribution.
The File/source checksum helper drains an autorelease pool for each 1 MiB read;
otherwise Foundation can retain temporary checksum buffers until the enclosing
callback returns. An initial iPad trial without this helper bound is retained as
harness evidence and excluded from final File memory comparisons.

Source/input generation, launch, install, file transfer and result collection are
outside phase timing. Phase metrics persist immediately, including on a thrown
error. A process death can leave the active phase incomplete; retain it as a
failure/incomplete trial rather than silently retrying. Successful stages close
all stores and synthetic sessions before the final report. Whole-process OS and
filesystem caches are uncontrolled; a fresh process is not cold physical I/O.

```sh
python3 Experiments/DeviceCapacity/run.py --device DEVICE-ID --case strings \
  --output /tmp/new-capacity-strings-trial
python3 Experiments/DeviceCapacity/run.py --device DEVICE-ID --case binaries \
  --output /tmp/new-capacity-binaries-trial
python3 Experiments/DeviceCapacity/run.py --device DEVICE-ID --case representative \
  --source-directory /tmp/extracted-stopped-v1 \
  --output /tmp/new-capacity-representative-trial
```

The source directory must contain exactly one SQLite file and its WAL/SHM.
The script transfers only a copy into this trial's isolated app directory. It
requires an actual-process/active-scene launch receipt and a passing final stage
report. It does not retry a failed or incomplete stage. Its 25-minute guard is a
laboratory hang guard, not supported production latency. Run devices concurrently
only for local stages; use isolated trials for actual network comparisons.
