# T07 zone sharing device protocol

Local-only signed host; excluded from CI. Export the committed runtime with
`prepare_demo.py DEMO NEW_EXTERNAL_HOST`. Use the test Development container only,
fresh run UUID and fresh store/session locations. Do not reset the container,
copy native stores or replay a stage whose `.started` marker exists. Keep each
writer process alive until independent peer observation. A launch receipt is not
a protocol result.

1. XR/other account: `identity`, replica `peer`; protect `identity.json`.
2. iPad/owner: transport that identity to its run/owner directory, then `seed`.
   Three private graphs: A read-write share, C read-only share, B unshared control;
   A includes a file. Retain the owner through peer observation.
3. Protect/copy `invitations.json` to run/peer; `accept` on XR. Check actual shared
   import, complete local/native inventories, contents, file and read-only denial.
4. XR `peer-edit`: mutate A to 2 and publish; retain it through iPad `observe-owner`.
5. iPad `owner-edit`: mutate A to 3; retain it through XR `observe-peer`.
6. Copy only the invitation capabilities to a new `fresh` replica; `recover`
   inspects already accepted shares and recovers actual cloud data into empty
   native stores. No native store/token copy is allowed. A separate `current`
   replica supports a new empty recovery after source hardening, without replaying
   an existing stage or reusing its files.

Use `PublicMirroredProbe/launch_probe.py` with `--zone-sharing STAGE RUN REPLICA`.
Require separate passed stage reports and exact inventories; private B must not
appear in the participant's shared zones. Native acceptance and complete local
import are distinct observations. This protocol does not certify revocation,
leave, account switching, crash recovery, APNs or background delivery.
