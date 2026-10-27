# C04a shared observation laboratory

The [contract](../../docs/design/graphevo-2-shared-observation-experiment.md)
defines exact-descriptor, one-handle grouping. This opt-in package-only candidate
does not replace public `observe` or `publisher`. It uses the default model and
current query adapter; C02b's alternative model is deliberately not combined.

```sh
swift build -c release --product ObservationCostProbe
swift build -c release --show-bin-path
python3 Experiments/SharedObservation/run.py --executable /absolute/ObservationCostProbe \
  --output /tmp/new-c04-run
```

The full matrix uses five repetitions over five node/file cases, one/eight/32
observers and equal/mixed descriptors. Each case seeds a new owned local store,
closes it and copies its complete directory for every process/variant. Defaults
produce 300 timed rows. Use `--cases small --counts 1,8 --repetitions 1` for
functional screening. Failed stages are preserved and never retried in place.
No generated stores, logs or transport identities enter Git.

Startup creates observers sequentially and waits for each fresh initial state;
a join always requests a new native read, so shared startup is not expected to
collapse to one read. The update wave changes one Entity, then every observer
must receive a new local view with the expected identity/revision. Equal queries
select that Entity; mixed queries select different Entities and still receive
broad invalidation. No comparison changes query budgets, decoding or files.

`waveMS` includes the write and all deliveries; `writeMS` and `tailMS` disclose
that overlap. `waveCPU` is process user+system CPU, not wall time. Memory is a
2-ms sampled whole-process RSS peak, including open/startup/wave; it is not an
allocation guarantee or a claim about the query alone. `executionScopes` counts
distinct delivered read views (a lower bound on independent native queries).
`sharedExecutions` additionally counts candidate native read attempts between
startup and delivery. A native hint is not a cloud import-completion certificate.

Seed files contain four repeated deterministic binary patterns of 1 or 10 MiB.
They test unrelated body avoidance, not representative media compressibility or
file-read envelopes. OS caches are uncontrolled. Never run timing alongside
builds/tests; retain intermediate binaries and rerun representative cases on new
fixtures before selecting a direction. CI smoke has no timing threshold.
