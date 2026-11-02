# GraphEvo 2 — explicit CI checkpoints

Updated: 2026-11-02. Alpha work uses explicit reviewed checkpoints with two
profiles. A skipped job is not a successful validation. Review and relevant local
checks precede CI; merge follows the selected successful checkpoint.

## Profiles

| Trigger | Scope |
| --- | --- |
| Ordinary v2 PR, no checkpoint label | No macOS/iOS runners |
| `ci-checkpoint` on a v2 PR | V2 store, runtime and model suites on macOS/iOS; Swift 6 model and process consumers on macOS |
| `ci-full-checkpoint` on a v2 PR | Every legacy/v2 suite on both platforms, including capacity regression; Swift 6 consumers |
| Both checkpoint labels | Full takes precedence |
| Manual dispatch on `codex/*`, `profile=v2` | V2 profile |
| Manual dispatch, default `profile=full` | Complete suites |
| PR/push on v1, stable or release lines | Complete suites, regardless of profile input |

The v2 profile retains all functional runtime/store/model cases except
`twoThousandRecordNativeSortFitsTheUnchangedStepBudget`. That capacity fixture
belongs to the full profile; the smaller 300-record multi-chunk/every-page sort
regression remains in the v2 profile. No tests are deleted or disabled. Current
counts are 593 v2 macOS functions and 592 v2 iOS functions; these are observed
counts, not fixed gates to edit whenever tests are added.

Use the full profile for changes to legacy behavior/shared legacy foundations,
test infrastructure or profile selection, milestone integration, alpha/beta tags
and release acceptance. Use the v2 profile for focused v2-only increments. A
relevant capacity regression must also run locally when modifying that behavior.
Local checks should follow the change, not repeat every unchanged suite after
every documentation edit. Full validation remains available and required at the
stated boundaries; fast validation never certifies a full milestone.

`Scripts/run_ci_tests.py` defines both command lines for local/remote execution;
its unit tests guard the target selection, full-profile absence of exclusions,
invalid requests and empty/failed iOS result rejection. Full means no test
filters. There is no changed-file guesser or silent native/platform fallback.

```sh
python3 Scripts/run_ci_tests.py --profile v2 --platform macos
python3 Scripts/run_ci_tests.py --profile full --platform macos
python3 Scripts/run_ci_tests.py --profile v2 --platform ios \
  --destination 'platform=iOS Simulator,id=DEVICE-ID' \
  --result-bundle /tmp/new-graphevo-ci.xcresult
python3 -m unittest discover -s Scripts/tests
```

## Workflow

1. Implement and run the affected local checks. Open the focused PR without a
   checkpoint label, directly against `codex/graphevo-2`.
2. Review, correct and re-review. Choose v2/full from the behavior changed.
3. Add the appropriate checkpoint label only to the reviewed code. A source
   change on a labeled PR requests a replacement checkpoint; remove both labels
   before intermediate fixes, then review before requesting it again.
4. After the selected checks pass, merge within the maintainer's authorization.
   A request for review alone does not authorize CI or merge.
5. Record the exact tested head, profile and run. Final docs-only integration
   notes may reuse the checkpoint only when shipping/test/consumer/workflow
   inputs are unchanged. Never turn a skipped job into green evidence.

The existing `CI` workflow can also be dispatched with a branch/ref and profile.
If default-branch dispatch registration is unavailable, use the PR-label route;
do not merge v2 into `develop` just to register a workflow. Alpha integration
pushes do not repeat the checkpoint. Automatic v1/stable/release validation and
the existing master consumer fixture remain enabled.

The trigger remains `pull_request`, never `pull_request_target`, with read-only
permissions and no new secrets. Unrelated labels neither request validation nor
cancel a running checkpoint. Superseded source/checkpoint runs are canceled.
Jobs have a twenty-minute ceiling rather than the default multi-hour limit.

## Build and experiment boundaries

The ordinary package contains only the library and its test targets. The
package-private experimental executables require `GRAPHEVO_BUILD_LABS=1`; normal
builds, consumers and CI do not compile/link them. Their local commands are in
`Experiments/SharedObservation` and `Experiments/IdentityLookup`. Do not expose
package diagnostics publicly merely to make a lab an external product.

macOS uses SwiftPM tests without Xcode's instrumented test build. iOS uses the
single-product `GraphEvo` scheme. Compiler/test-discovery dependencies may still
build legacy test sources in the v2 profile; execution selection is explicit.
Simulator boot overlaps compilation instead of imposing a separate boot wait.
The build already resolves dependencies; there is no duplicate resolve step.
No build cache or routine result-bundle upload consumes additional Actions storage.
Physical CloudKit/device protocols and experimental timing/smoke runs stay local.

The legacy retention tests seed valid boundary-sized histories once and invoke
normal durable transitions to test compaction at the unchanged 2-MiB limit. They
no longer perform hundreds of preparatory fsync/history-decode cycles. The export
test uses a small vector PDF to test the same save/reopen contract without
creating a PDF page from an image. Crash/journal/KVS/corruption cases are retained.

## Diagnostics and evidence

Successful iOS runs print concise actual result counts and reject empty/failed
bundles. Failed runs retain text logs and a summary for one day. Full native
xcresult uploads require `ci-diagnostics` or dispatch `diagnostics=true`, also for
one day. Retrieve needed native diagnostics before expiry. No raw stores,
identities, signing data or private support archives enter Git or CI.

Keep historical runs/results unchanged, including failed checkpoints. Profile
changes do not retroactively weaken their claims. No historical account artifact
or budget is modified here, and no measured account-wide storage saving is
claimed. This policy introduces no tag, release or beta acceptance.

## Local verification of the revised profiles

Both default/opt-in manifests validate; both experimental products still build
when explicitly enabled. Six profile/empty-result guards pass. The v2 commands
execute 593 macOS and 592 iOS functions; full commands retain 925 macOS and 923
passed iOS functions plus the one known legacy skip. All three independent local
consumers pass. The complete local iOS test interval is 41.78 seconds on a warm
simulator; this is not a cold GitHub runner timing claim.

The previous #362 iOS job spent 272.27 seconds in image/PDF export and 50.74/
11.37 seconds in the two legacy retention cases. Revised retention cases run in
roughly 0.1–0.2 seconds locally, still exercising the real 2-MiB boundary. Machines,
cache state and instrumentation differ, so no cross-environment speed ratio is
claimed. Reviewed full [checkpoint #365](https://github.com/bbruno84/GraphEvo/actions/runs/41448941858)
passes on `19275350aad6e0b450fecdc17dc2606790dd0429`, integrating through #138.
MacOS retains all 925 functions and both Swift 6 consumers; iOS retains 923 passed
functions, zero failures and the known legacy skip. Job-log spans excluding runner
queue are 279 seconds macOS and 768 seconds iOS, versus 425/837 seconds for #362.
The macOS retention cases each take 0.23 seconds. The complete iOS profile remains
costly; normal v2 checkpoints omit its legacy execution. Cold remote v2-profile
latency has not yet been measured. In this run iOS also waited roughly ten minutes
for a runner, separately from execution; queue availability is not a test speedup.

Final integration notes are documentation-only. Shipping/test/manifest/scripts/
consumer/workflow inputs match the tested commit; library Sources remain unchanged.
