# In-memory read coherence — CI follow-up (2026-10-30)

PR #100's first CI run `41054948782` passed iOS but failed macOS in
`broadRelationActionFileChangesAndFailureRecoveryRemainVisible` with
`corruptIdentity`. The 14 migration tests passed. Expected poison-transformer
and injected migration-failure logs are separate controls, not that failure.

Investigation found that the runtime pinned SQLite reads but allowed an in-memory
multi-fetch read to overlap a local commit. A deterministic regression on the
unchanged implementation pauses a read after its first fetch, commits another
row and resumes it. It fails both the queue-order and same-view assertions: the
second fetch sees the newly committed row. The read can therefore combine node,
property or topology inventories from different local states. This establishes
the missing coherence mechanism; it does not claim a stack trace for the original
CI's exact failing metadata check.

The runtime now admits complete in-memory read scopes through its existing FIFO
writer gate. Reads arriving during a memory writer wait for its committed state;
read cancellation removes its queued request without invoking the body. Close
still drains admitted work. SQLite retains its pinned concurrent read behavior,
and does not allocate an additional gate request. No native model, query budget,
identity check, observation predicate or result error is weakened.

The pending-write test now covers both explicit behaviors: SQLite sees only the
prior committed state while a writer is pending; in-memory reading queues until
the writer completes. Another resource remains independently usable in both
cases. This intentionally replaces A2's former lack of a memory snapshot
guarantee; it does not establish cross-process/cloud consistency. Native privileged
in-memory operations also own the writer gate and must not reenter a read on the
same resource while awaiting completion.

Selected migration/observation and runtime transaction suites pass after the
change, including the before/after regression and cancelled queued reader.
Raw local logs remain outside Git under `/tmp/graphevo-memory-read-*` and
`/tmp/graphevo-m2a-coherent-*`. Exact-head CI must pass before #100 is merged.
