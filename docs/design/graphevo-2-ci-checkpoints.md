# GraphEvo 2 — explicit CI checkpoints

Selected by the maintainer on 2026-10-31 to reduce repeated alpha CI runs and
retained diagnostic storage. This changes remote execution frequency, not the
meaning of beta/stable acceptance or the need for review and relevant local checks.

## Operating policy

Ordinary PRs targeting `codex/graphevo-2` do not allocate macOS/iOS runners. Their
full validation jobs are explicitly skipped. Pushing a merge to that alpha
integration branch does not repeat the same full suite. Do not describe either
case as tests having passed remotely.

The required order is **review → CI → merge**:

1. Complete implementation and relevant local checks; open the PR without the
   `ci-checkpoint` label.
2. Review the change, resolve findings and re-review the corrections. Record the
   reviewed head and any remaining limits before starting remote validation.
3. At a required checkpoint, request full CI on that reviewed head immediately
   before the authorized merge. CI is the final validation step, not a prerequisite
   for starting review. Do not label a PR while review fixes are still in progress.
4. Merge only after required checks pass and the maintainer authorizes the merge.
   A request for review alone does not authorize CI or merge.

If source changes after review, remove the label before intermediate pushes,
complete focused re-review and appropriate local checks, then request any required
replacement checkpoint. Do not silently reuse an earlier-code green run. A pure
documentation change does not by itself justify rerunning unchanged library tests.

A full alpha checkpoint is explicit:

- Add the `ci-checkpoint` label to a focused PR after review is complete and it
  is ready for the final pre-merge validation. Both existing macOS/iOS jobs run.
  Further source commits on that labeled PR rerun the checkpoint, so it always
  refers to the actual head.
- For an integration-branch checkpoint, dispatch the existing `CI` workflow with
  the desired branch/ref, for example `gh workflow run ci.yml --ref codex/graphevo-2`.
  If GitHub's default-branch dispatch registration is unavailable, use the PR-label
  route; do not merge unfinished v2 code into `develop` just to enable dispatch.
- Record the exact tested head and successful run. Checkpoints occur at agreed
  delivery boundaries, on explicit maintainer request, and before alpha/beta tags.
  Any material code change after a required checkpoint needs a fresh checkpoint
  before claiming that boundary is validated.

Review and appropriate local verification still precede every alpha merge.
Select checks from the changed behavior: affected tests, package/consumer builds,
manual/device validation or documentation/script checks. Do not run an unchanged
full suite merely to produce a green badge for documentation. Never bypass failed
relevant local checks. Use the direct focused-branch integration workflow.

Automatic full CI remains enabled for PRs/pushes to `develop`, `master` and
`release/**`. The existing master consumer fixture also remains enabled. This
alpha policy does not weaken release or v1 validation. Obsolete PR targets matching
`codex/v2-*` are removed; new v2 increments target `codex/graphevo-2` directly.

The label trigger uses normal `pull_request`, not `pull_request_target`, and adds
no write permission or secrets to untrusted jobs. Adding unrelated labels does
not restart an already labeled checkpoint. Removing the checkpoint label stops
future automatic checkpoint runs on source updates; it does not cancel work
already running. Existing concurrency still cancels superseded PR runs.

## Validation scope

CI validates the library: package manifest/build, unit/regression tests on macOS
and iOS, diff formatting, the Swift 6 model consumer and independent-process
consumer integration. Experimental harnesses under `Experiments/` are not CI
steps, including their functional smoke modes. ObservationCostProbe,
IdentityLookupProbe and ConsolidationCosts run locally when an experiment needs
them, with separate reports. Physical CloudKit/device protocols also remain
local, explicitly documented verification. No experimental timing or smoke run
is a release-library gate merely because its harness exists.

The previously installed three experimental smoke steps were removed at the
maintainer's request. Keep historical CI evidence unchanged. Regression tests
for adopted library behavior remain in the library suites; removing experimental
harness execution does not authorize bypassing a failing regression test.

## Storage and evidence

The full result summary stays in the workflow log. An iOS xcresult bundle is
uploaded only after a failure and retained for **three days**, reduced from seven.
If a failure needs longer investigation, retrieve its diagnostics before expiry
and retain them privately. Do not commit raw stores, account identity, engine
serializations or signing files as a substitute for artifact retention.

At inspection time GraphEvo had zero active workflow artifacts. The supplied
storage warning concerns the account; no account budget or other repository was
modified and no historical artifact/run was deleted. Reducing build frequency
primarily removes repeated execution; short failure-only retention limits future
artifact accumulation. Do not claim a measured storage saving from this change.

Historical result reports keep their actual CI/run evidence. Record the last full
checkpoint in development status; skipped alpha jobs never replace it. No tag or
release is implied by introducing this policy.

GitHub references: [job conditions and skipped checks](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-jobs-with-conditions),
[workflow events and dispatch](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows),
[artifact retention](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/remove-workflow-artifacts).
