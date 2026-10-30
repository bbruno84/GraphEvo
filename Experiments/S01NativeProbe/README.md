# S01 public native sharing and fresh recovery

Use only the authorized Development test container, owner iPad and different-account
iPhone XR. This host extends the public A6 fixture with fresh replica directories;
it never resets cloud data, converts old alpha files or copies a SQLite into a
new replica. Read [S01](../../docs/design/graphevo-2-persistent-schema.md) and the
[A6 protocol](../A6NativeProbe/README.md) first.

```sh
python3 Experiments/S01NativeProbe/prepare_demo.py /path/to/GraphEvoDemo /tmp/new-S01-host
```

Build/sign a disposable host against this checkout. Check its actual signed
container/environment, preserve a source revision/executable hash manifest, and
install on both devices. The original configured demo must remain unchanged.
The generated functional consumer uses public GraphEvo APIs and explicit
`schema: .nativeIdentity`; no raw contexts or testable module access are added.

Use a new run UUID and the acknowledged [launcher](../PublicMirroredProbe/launch_probe.py)
with `--a6 <stage> <run-UUID>`. A stage reserves its report before work. Preserve
every failure; never replay a consumed mutation or treat a launch acknowledgement
as a successful Graph operation. Keep launch/receipt/report evidence together.
Reports/transports remain under `GraphEvoLaboratory/NativeIdentityFiles/<UUID>/`.

1. iPad `prepare-owner` creates only the native resources/setup and report, leaving
   the fixture unseeded. XR `identity` produces the protected recipient transport.
   Transfer that run-bound `identity.json` to the iPad's existing case directory.
2. iPad `seed-and-invite` creates A with 512-byte/10-MiB files, personal B with its
   control file, prepares distinct share boundaries and invites the pinned
   recipient in the **same retained seed process**. Transfer only `fixture.json`
   and `invitation.json` to XR; keep the owner alive through peer observation.
3. XR `accept` verifies exact initial content/metadata/digests, mappings, full
   local native integrity, B absence and byte-exact large-file export.
4. XR `recover-initial` creates `recover-initial-replica/` only if absent. It
   reuses the original invitation (already accepted is not native reassignment),
   independently recovers A into new private/shared stores and exports to a new
   filename. It receives no source SQLite or native sidecar.
5. Continue the original A6 `add` / owner `observe-add`, `replace` / owner
   `observe-replacement` sequence, transferring the addition transport as needed.
   Each writer remains open until the other account independently observes it.
6. XR `recover-replacement` creates a second absent directory and recovers the
   updated graph, including participant addition, stable large-file identity,
   changed revision/filename and exact replacement bytes. Export publication uses
   its own filename and does not overwrite the original exports.
7. Continue XR `delete` / owner `observe-deletion`, owner `owner-cascade` / XR
   `observe-cascade`, then owner `owner-final` / `owner-final-boundary`. Preserve
   control B and exact non-nil distinct boundaries in the final owner check.

Where possible independently collect the two fresh exported files and check their
10-MiB contents. After final peer observation, stop only the acknowledged probe
processes and preserve complete case directories. Inspect copied stores with the
public Core Data metadata API to verify `GraphEvo.v2.schema.1` on both resources
of each fresh pair. Do not parse private Core Data/CloudKit records or publish
identity/invitation transports, raw logs, stores or personal signing data.

Fresh local resources do not imply an empty cloud account. Setup, local save,
mapping, process relaunch and independent recovery are distinct evidence. This
fixture does not implement consumer-format migration/admission, prove global sync
completion, production deployment, account switching or arbitrary crash recovery.
