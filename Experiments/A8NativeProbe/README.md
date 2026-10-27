# A8 live query observation probe

Read the demo README/AGENTS. Prepare a new disposable configured demo with
`python3 Experiments/A8NativeProbe/prepare_demo.py /path/to/GraphEvoDemo /tmp/GraphEvoA8Demo`,
then build its GraphEvoDemo scheme for devices against this library checkout.
Preserve the source demo and signing settings. No generated app/store, raw log,
recipient/invitation value or protected fixture belongs in Git.

This probe requires the retained successful A6 run
`291F43CA-76F3-4B93-B780-B6CFC8DD5F7D`: A's owner/files have been deleted,
its private invitation remains accepted on the XR, and B's original control
attachment remains exact on the iPad. Never reseed/reaccept that A6 run.
Use a new A8 UUID and one-use `--a8 <stage> <A8-UUID>` report for each stage:

1. `seed` on the owner iPad inserts two A8 entities and one edge into retained
   graph A; the child's existing scalar state starts off. The protected A8
   fixture pins all logical IDs and references the retained A/B IDs.
2. Copy only the new protected A8 fixture to the matching A8 directory on XR.
   `watch` there opens the existing A6 stores/share, starts async and Combine
   related-query observers, and waits for the initial two-entity fixture and
   both initial-empty results. Wait for READY before further writes.
3. `on` on iPad changes only the child's existing state property. Retain the
   native owner. Wait for ON-BOTH on XR; no one-shot polling or resubscription
   may rescue the related-query observers.
4. `delete` on iPad deletes the child and its edge while retaining the selected
   parent. Both XR observers must become empty after previously becoming present.
   PASS requires both transitions. The parent remains as retained test data.

Owner stages verify B's complete control metadata and exact bytes before/after.
XR verifies B is absent from its catalog. No share creation, invitation,
permission mutation, account switch, cloud reset or failed-stage replay is
allowed. Unique report files reserve stages before work; retain failures and
inspect actual state before designing a new recovery stage. Do not repeat a
reserved mutation because a log/timeout is ambiguous. The live window is bounded
at 240 seconds; writer lifetime must span independent observation. This is one
cross-account foreground run, not offline/background/replay or minimum-OS certification.
