# Cost matrix native attachment lifecycle

Read the source demo README/AGENTS and the [matrix](../../docs/design/graphevo-2-experiment-matrix.md).
Prepare outside both checkouts with `python3 Experiments/CostMatrixNativeProbe/prepare_demo.py
/path/to/GraphEvoDemo /tmp/GraphEvoMatrixDemo`. The wrapper reuses the complete
[A6 one-use procedure](../A6NativeProbe/README.md), adds explicit split-property
assertions, and leaves the original demo untouched. Build the disposable project
against the final matrix candidate. Record its exact library revision and build.

Use a fresh run UUID and the same `--a6 stage runUUID` CLI/protected transport
paths as A6. Do not reuse any historical fixture/stage. Owner iPad and other-account
XR must remain unlocked; install the same signed build on both. Run seed/identity,
invite/accept/export, participant add/owner observe-add, participant replacement/
owner observe-replacement/export-replacement, delete/observe-deletion,
owner-cascade/observe-cascade and owner-final-boundary. Each launch terminates the
previous process, testing reopen as well. A/B native boundaries must remain
non-nil/distinct, mappings complete, metadata/digest/original bytes exact, B
unchanged on owner and absent on participant. Keep the native owner running until
independent peer observation. A local PASS/write is not export completion.

Report all one-use failures, pending intents and recovery separately. Never
blindly replay a failed mutation, reset the CloudKit schema or inspect private
native bookkeeping. Timing/RSS for this probe is descriptive device-stage cost,
not the independent local Release benchmark or an offline/conflict guarantee.


For autonomous continuation after the explicitly launched seed/identity stages,
run `python3 Experiments/CostMatrixNativeProbe/run.py --run UUID --output
/tmp/new-external-evidence`. It reserves each subsequent launch, transfers
protected run-bound transports (including exact replacement metadata), polls
bounded reports, and aborts without replay on any failure. The output directory
must be new. A missing initial report is not authority to repeat a write; retain
its launch logs and investigate. A separate verified read-only relaunch may
resume observation without resubmitting a mutation.

The final M03b build adds one-use `matrix-query-owner` / `matrix-query-peer`
read-only stages on the retained completed fixture. They verify typed query,
count and metadata projection under 32 KiB, empty A, exact retained B content
on owner, and B absence on the other account. They do not replay the lifecycle.
