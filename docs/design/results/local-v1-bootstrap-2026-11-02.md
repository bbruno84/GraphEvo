# MF09 — local v1 bootstrap and restart evidence

Date: 2026-11-02. Scope: [MF09](../graphevo-2-local-v1-bootstrap.md), package-only
conversion/recovery followed by ordinary local S04 opening. No public/default
opener, schema or durable migration/cloud/backup format is changed.

## Outcome

The existing converter now returns a usable GraphStore only after conversion
commit, native cleanup and ordinary read availability. Pre-commit failures throw;
post-commit failed opening/cancellation preserves the receipt/mapping beside the
separate availability failure. Admission remains reserved through this sequence.
No source file replacement, cloud startup or consumer-body replay is introduced.

Final shipping source is `9dc5cfaf52e70256588d66467726ab9db665d8dd`.
Initial physical conversion/recovery stages use `aac1f60`; the final two recovery
checks use all source bytes from the final revision. The last code correction
records an already-started session's loaded document, so local bootstrap refuses
promptly while account startup remains unknown instead of awaiting its network
work. The physical protocol never starts a cloud session.

## Deterministic and local checks

The full local macOS suite passes 923 functions: 331 legacy, 487 store,
76 runtime and 29 model. The iOS store/model suites pass with the initial twelve
bootstrap cases; final iOS bootstrap/cloud-session checks pass all 37 functions,
including all fifteen bootstrap cases. Both independent Swift 6 consumers,
package manifest and diff validation pass. CI validates the final reviewed source
separately, after review and physical checks.

New tests cover:

- realistic known-model invoice/category properties, Decimal, archived values,
  tags/groups, dates, topology and a 2-MiB binary property;
- backup verification and unchanged source checksum before returning S04 access;
- restart and same-volume path relocation with the same receipt/UUID mapping,
  preserving an ordinary v2 edit and one backup;
- post-commit native-opening failure with committed receipt and no reapplication;
- pre-save rollback/cancellation and post-commit cancellation outcome;
- admission before the destination exists and during final opening, including
  same-ID open/create, destination aliases and concurrent conversion;
- active/differently registered graph refusal without implicit rebinding;
- invalid/replaced source and live in-process legacy ownership exclusion;
- failed native detachment retaining ownership and files rather than admitting
  another owner; unrelated graph resources still progress;
- unrelated cloud bindings versus the target's binding, concurrent binding and
  conflicting session restoration without implicit activation;
- an empty converted graph's stored participation gate refusing local readiness;
- pending account startup returning busy before source/destination work.

The native read-admission check and pending-session refusal were review
corrections before the final checkpoint. Expected Core Data external-data cleanup
logs occur during injected rollback; tests verify rollback/retry and payload
integrity rather than suppressing the fault path. Deliberately quarantined native
resources remain owned/on disk until process exit.

## Physical protocol

Devices: iPad (10th generation), iPadOS 27.0; iPhone XR, iOS 18.7.11. Each uses an
independent fresh local fixture and distinct GraphID. They are not two conversions
being published into one cloud graph. A disposable signed GraphEvoDemo contains
an external-only bridge over the committed package. The original demo checkout
is unchanged. Raw sources/stores/logs/proofs remain local and outside CI.

The source contains five primitives: invoice, category, directed relationship,
action and a relationship with absent endpoints. Checks include Decimal amount,
a 2-MiB binary property, retained `appDataVersion`, per-property native version,
tags/groups, an explicit creation date and an absent category creation date.

| Stage | iPad | XR | Verification |
| --- | --- | --- | --- |
| Initial bootstrap | Pass | Pass | Backed-up v1 conversion returns ordinary S04 read availability; full data/topology validation and five normal local PH items |
| Process restart/recovery | Pass | Pass | Open normally, apply one later v2 edit, close, then repeat bootstrap; recover identical native receipt/UUID map and the same backup while retaining the edit |
| Final-source recovery | Pass | Pass | Reopen through bootstrap on final source, retain the edit, exact map and one backup; no mutation replay |

All six stages pass. Initial bootstrap verifies/restores the complete legacy
`.geb` using the original v1 model and confirms original legacy IDs/content.
Every stage verifies the source SQLite checksum and retained binary contents.
Targets have new store UUIDs and graph-aware random node identities; the original
source is neither overwritten nor relabeled. Generated reports distinguish local
commit from ordinary availability.

There is **no CloudKit session, import, export or account operation** in this
physical protocol. Stage reservations are never replayed. Launch/report paths
are relative to the current app data container. Request IDs and proof receipts
are persisted, while absolute sandbox locations are supplied again. The final
demo processes are stopped after evidence collection; fixtures remain available.

## Boundaries retained

This closes the bounded local bootstrap/opening checkpoint. It does not certify
production/historical v1 wrappers or schemas, source completeness against the old
cloud, physical power loss, external-process writer exclusion, large-scale
conversion or public opening integration. Local Data preservation is not proof
that an oversized inline property can be uploaded; moving binaries to attachments
remains the consumer's responsibility. Authoritative new-cloud activation is a
separate next route, with one selected converted graph/mapping.

The S04 native-sort work-budget follow-up from P03 also remains open. No release,
beta acceptance, alpha-store converter or new migration registry is introduced.

## Reviewed checkpoint and integration

[PR #136](https://github.com/bbruno84/GraphEvo/pull/136) integrates the bounded
route after review and full [CI #355](https://github.com/bbruno84/GraphEvo/actions/runs/41422586643)
on `39fb59afe65d6a55c9919e6d35489603afef68b1`: macOS suites and both consumers;
921 passed iOS functions/1034 invocations, zero failures and one known legacy
alias skip. Shipping source remains `9dc5cfa`. Final integration edits are
documentation-only, with exact source/test/consumer/workflow equivalence to the
reviewed checkpoint. No laboratory target or physical test is added to CI.
