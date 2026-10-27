# A6 native attachment probe

Use only the authorized synthetic Development fixture. Read the demo's
README/AGENTS before preparing a disposable copy. Keep signing/configuration,
identity/invitation transports, native logs and stores outside Git.

```sh
python3 Experiments/A6NativeProbe/prepare_demo.py /path/to/GraphEvoDemo /tmp/GraphEvoA6Demo
xcodebuild build -project /tmp/GraphEvoA6Demo/GraphEvoDemo.xcodeproj \
  -scheme GraphEvoDemo -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/GraphEvoA6Build -allowProvisioningUpdates
```

Launch the configured demo with `--a6 <stage> <new-run-UUID>`. Every stage
reserves its report before opening/mutation; never replay a consumed ticket.
Paths are under `Library/Application Support/GraphEvoLaboratory/A6/<run-UUID>/`.
Native owners remain retained after local success for independent observation.
The source demo checkout remains unchanged. No cloud reset belongs to this test.

1. Owner iPad `seed`: A has an owner plus 512-byte/10-MiB attachments; B has its
   own owner/control file and distinct native share boundary. Participant XR
   `identity`: protected recipient. Transfer `fixture.json` iPad→XR and
   `identity.json` XR→iPad through protected, run-bound transports.
2. Owner `invite`: only the pinned participant joins A. Transfer its protected
   `invitation.json`; XR `accept` requires actual exact bytes, metadata, checksum,
   mappings and B absence, then independently exports the large file.
3. XR `add`: insert a new 512-byte file through explicit shared assignment;
   preserve/recover native pending intent without replay if needed. Transfer
   `addition.json` XR→iPad; owner `observe-add` verifies the same ID/content.
4. XR `replace`: replace the original large file with different exact bytes and
   filename, preserving ID. Owner `observe-replacement` requires recovery and
   unchanged B. The optional read-only `export-replacement` independently exports
   the new exact bytes with the current exclusive-publication implementation.
   XR `delete`; owner `observe-deletion` requires only that large
   file to disappear, with the other files and B intact.
5. Owner `owner-cascade`: delete the A owner and its remaining owned files.
   XR `observe-cascade` independently observes those IDs disappear and B absent.
   Owner `owner-final` independently checks complete A removal and retained B file.
   `owner-final-boundary` is a separate read-only ticket for the final strict
   check that both mapped share boundaries are non-nil and distinct.

Poll windows are bounded. Local save/acceptance/setup are not file recovery.
The probe samples process resident memory every 20 ms during each stage; logs
baseline, sampled peak and delta, including framework/setup costs. It cannot
prove the absolute transient maximum or attribute all memory to attachments.
Stages use synthetic repeated bytes; do not infer arbitrary-file performance,
physical external-storage placement, streaming, offline retention or a global
sync barrier. Preserve failed reports and diagnose without replaying writes.
