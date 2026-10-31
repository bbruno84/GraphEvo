# T03 — automatic conflict policy CloudKit result, 2026-10-31

Result: **all eight ordered stages passed**, once each, on iPad and iPhone.
Both automatic policies, deterministic edit ordering/tie, current local 4 versus
frozen 3, partial success, targeted retry and delete-wins converge without consumer
resolver callbacks. Independent empty recovery agrees with complete server state.

## Provenance and isolation

- Runtime commit `348636e`, on `codex/v2-conflict-policies` directly from reviewed/
  merged #114 (`4e9d30c`). Disposable signed host contains the committed production
  runtime and only the external [T03 bridge](../../../Experiments/ConflictPolicyProbe/README.md).
- Native S03 is unchanged; wire/session/transport versions are 2/3/2. The injected
  clock supplies the real consumer timestamp hook; no raw date editing or native
  tag fabrication. Clock values are intentionally synthetic ordering inputs.
- iPad (10th generation), iPadOS27.0, owner; iPhone18 Pro, iOS27.2, peer and later
  fresh replica. Same account confirmed privately. No account identity logged.
- Signed entitlements inspected: `iCloud.com.valerioburiani.GraphCKDemo`,
  Development. Seven zones under a fresh GE2-T03 run, seven new stores per replica.
  No reset, schema deployment, old fixture conversion, store copying or zone purge.
- Each stage has its original launch/scene acknowledgement and separate passed
  report. Unique started reservations prohibit replay; all eight passed on their
  first invocation. Owners stayed alive through independent observations.

## Observations

| Case | Confirmed outcome |
|---|---|
| Initial recovery | Seven empty peer stores recover exact baseline, dates and local policy configuration; no upload feedback. |
| U: peer3/date100 versus owner2/date200, plus unrelated leaf30 | Cloud2 wins. Leaf alone succeeds in the original partial batch; it is acknowledged once. No retry needed for the loser. |
| L: frozen peer3/date300, current peer4/date400 versus owner2/date200 | Resolve from current4, keep date400, rebase real server metadata and publish with one targeted retry. Frozen3 is never published or acknowledged as4. |
| C: cloudWins, peer3/date300 versus owner2/date200 | Cloud2 wins despite the later local edit date. |
| T: both dates200 | Cloud2 wins the tie under lastEditWins. |
| D: pending local delete versus newer server update | Native record-ID deletion succeeds; both replicas end absent. |
| R: pending associated save versus remote deletion | Real unknownItem becomes remote deletion; local update removed, no automatic recreation. |
| B: independent control | Peer99→100/date500 publishes through the same engine; other inventories remain exact. |
| Reopen | Local choices, exact dates, policy configuration and empty queues persist without a fetch. |
| Owner/fresh recovery | Independent owner and newly empty stores recover U2+leaf30, L4, C2, T2, B100, D/R empty. Full native zone inventories match typed local records and dates; no import feeds upload. |

Final verification enumerates all scoped logical nodes and all CloudKit zone
modifications from nil tokens (100-record bound, moreComing refused), checking full
body/date equality and actual nonempty server change tags. Exact report counts
separate successful publication from resolved conflicts. Private session inspection
confirms matching account and bindings containing only graphID/zone identity.
Original stage reports, pinned export, signed build, frozen attempts and stores/
zones remain retained outside the repository, with no payload/account logs committed.

## Local validation and limits

The full local macOS suite at `348636e` passes 663 functions:331 legacy,238 store,
71 runtime,23 model. Subsequent final-review tests additionally cover same-cut
stale saves after deletion, both known/unknown date directions, unassociated
unknownItem refusal and replayed conflict receipts after newer edits. Their
final local run passes **667 functions** (331 legacy,242 store,71 runtime,23 model).
The final policy-only iOS18.5 rerun passes18 functions/25 expanded cases. Manifest,
diff and independent-process consumer checks pass. Final CI disposition is
recorded in the PR. The physical runtime is
explicitly pinned above; later test additions do not retroactively change it.
The selected iOS18.5 simulator pass covers65 functions/94 expanded cases, including
both policies, native receipts, PH and codec. Swift6 ModelConsumer passes.

Final review added deletion precedence over stale saves within one retained inbox
cut, verified in both orders deterministically. The physical protocol had separate
send/deletion stages and did not exercise this additional ordering; its eight
original passed reports are retained without replay or replacement.

This is small private entity-only evidence, not a production resource envelope,
global sync certificate or proof against clock skew. General structural and
shared-account conflicts, attachments, automatic scheduling, actual crash during
publication, consistent backup restore and lifetime deletion-trace cost remain
open. Injected receipts establish local atomicity/races; only this physical run
establishes actual server CAS and associated unknownItem outcomes for these cases.
