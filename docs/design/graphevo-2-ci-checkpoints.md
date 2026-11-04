# GraphEvo 2 — explicit CI checkpoints

Updated: 2026-11-04. Maintainer-selected alpha policy: review and adequate affected
local checks are the default merge gate. Remote CI runs only at agreed,
explicitly requested checkpoints, not on every increment, correction, pin or
push. Runner capacity/service failures do not block an otherwise verified and
authorized alpha merge. They are not passing evidence. Beta/release and published
tag acceptance retain their required remote gates.

## Profiles

| Trigger | Scope |
| --- | --- |
| Ordinary v2 PR, no checkpoint label | No macOS/iOS runners |
| Explicit `ci-checkpoint` label event on a v2 PR | V2 store, runtime and model suites on macOS/iOS; Swift 6 model and process consumers on macOS |
| Explicit `ci-full-checkpoint` label event on a v2 PR | Every legacy/v2 suite on both platforms, including capacity regression; Swift 6 consumers |
| Both checkpoint labels | Full takes precedence |
| Manual dispatch on `codex/*`, `profile=v2` | V2 profile |
| Manual dispatch, default `profile=full` | Complete suites |
| PR/push on v1, stable or release lines | Complete suites, regardless of profile input |

The v2 profile retains all functional runtime/store/model cases except
`twoThousandRecordNativeSortFitsTheUnchangedStepBudget`. That capacity fixture
belongs to the full profile; the smaller 300-record multi-chunk/every-page sort
regression remains in the v2 profile. No tests are deleted or disabled. At profile adoption,
counts were 593 v2 macOS functions and 592 v2 iOS functions; these are observed
counts, not fixed gates to edit whenever tests are added.

When a remote checkpoint is requested, use the full profile for legacy/shared
foundations, test/CI infrastructure, profile selection or milestone/tag/release
acceptance. Use the v2 profile for a focused v2 checkpoint. File scope alone does
not request remote CI for an ordinary alpha increment. A
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

1. Group the functional increment, UI/dependency pins and related corrections.
   Run adequate affected local checks; open the focused PR against
   `codex/graphevo-2` without checkpoint labels.
2. Review, fix and re-review locally. An ordinary alpha merge may proceed within
   the maintainer's authorization once those checks pass; remote CI is not an
   additional gate for every increment.
3. At an agreed checkpoint or explicit CI request, select v2/full and add the
   corresponding label to the reviewed head, or use manual dispatch. Only that
   label event requests a run: opening, reopening, pushing with a retained label
   and unrelated labels do not. A non-requesting event has its own concurrency
   group, so it cannot evict a queued or cancel a running requested checkpoint.
4. Do not automatically rerun for another pin, small correction or docs edit.
   Re-review affected inputs locally and group them into the next agreed remote
   checkpoint. Remove/re-add the label only when a new run is actually intended.
5. Hosted capacity/service failures or cancellation before execution are recorded
   as unavailable, never passing. Do not retry them by default. They do not block
   an otherwise locally verified, reviewed and authorized alpha merge. Actual
   test failures require investigation and adequate local verification; preserve
   the failure and any unresolved limitation rather than weakening checks.
6. Record exact local/remote scope, tested head, profile and result. A skipped job
   is not a passing checkpoint. Required beta/release and published-tag remote
   gates stay open if the service is unavailable; do not claim acceptance.

The existing CI workflow supports branch/ref dispatch with an explicit profile.
Automatic v1/stable/release validation and the master consumer fixture remain
enabled. Alpha integration pushes do not request another checkpoint.

The trigger remains `pull_request`, never `pull_request_target`, with read-only
permissions and no new secrets. Jobs retain a twenty-minute ceiling. This policy
changes when remote checks are requested, not test coverage or failure semantics.

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

The MF11 native-conversion suite and MF10 activation suite serialize independent
fixture cases within each suite. Each case creates a backed-up native migration;
running every fixture at once adds file/model work to the full runner's unrelated
one-minute cases. This bounds fixture bursts, not production concurrency: explicit
task-group migration/ownership tests retain their concurrent operations and all
other suites can still run in parallel, following
[Swift Testing's scoped serialization](https://developer.apple.com/documentation/testing/parallelization).
Test counts, assertions, payload sizes,
time allowances and profile selection remain unchanged. Hosted timeout/capacity
failures remain recorded; reviewed full checkpoint #381 passes both platforms
and Swift 6 consumers after this change. This is bounded acceptance, not a
stack-level diagnosis of prior timeouts. See [MF11 evidence](results/native-v1-staged-migration-2026-11-02.md).

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
