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
