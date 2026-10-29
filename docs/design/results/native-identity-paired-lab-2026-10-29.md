# Native identity paired laboratory readiness — 2026-10-29

Later the same day, [physical acceptance](native-identity-paired-devices-2026-10-29.md)
completed the controlled A5/A6 scope. This readiness record retains the initial
local checks and connectivity block as history.

## Outcome

The internal native-column paired opener and a disposable A5 host are ready for
controlled device acceptance. Public mirrored APIs/default models are unchanged.
This record establishes local adapter checks and host compilation, not CloudKit
setup, native assignment, import or cross-user recovery.

GraphNativeIdentityAccess retains local-only behavior by default. The laboratory
adapter opts into a mirrored pair only when both actual stores match the runtime
private/shared routing URLs. It reuses the same public alpha marker, model factory,
audited point resolver and common typed writers. No backfill, erase or migration
is invoked.

Fresh activation adds its marker detail after base control assignment. The
resolver now assigns the new detail back to the root's actual store, preserving
ownership regardless of which native store loads first. The offline test runs
both store orders and checks every native owned-row mapping. It seeds synthetic
imported rows without cloud options or fabricated share metadata, then verifies
equal node UUIDs remain graph/store scoped, incomplete projections fail and
shared writes without accepted permission metadata are rejected. The local-only
resolver remains unavailable on the paired cloud context.

The generated host uses a distinct NativeIdentity run directory and the existing
one-use A5 stages. It adds full native integrity checks to owner seed and A/B
recovery, and retains mutation owners for independent peer observation. Its
internal opener requires `@testable import GraphEvo`; public native mirrored
schema selection is still gated on physical acceptance.

## Verification

- Full `swift test`: 512 passed (322 legacy, 106 store, 61 runtime, 23 model).
- Selected Thread Sanitizer: 13 tests in four suites passed, including both
  native paired load-order cases, fresh stores and sharing plan/journal checks.
- Disposable native A5 host: generic iOS Debug build passed with local package
  linking; the original configured demo checkout was not modified.
- Package manifest and diff-format checks passed. No timing campaign or new
  performance envelope is claimed.

## Physical status and next evidence

The maintainer confirmed resetting the approved Development container. No probe
stage was launched: iPad installation lost its connection and XR's development
tunnel was unavailable. The maintainer was away and could not reconnect the
devices. Installation failure is environmental evidence, not a schema failure.
No invitation or new native operation was issued by this run. A local run UUID
reservation contains no completed cloud stage.

Use the [acceptance matrix](../../../Experiments/NativeIdentityPairedProbe/README.md)
when devices are available. Reconfirm controlled cloud state if old writers have
run since the reset; never infer cloud emptiness from fresh local SQLite files.
Required evidence includes both native setup events, owner A/B zones, independent
participant native identities/endpoints, participant additions/details, owner
recovery, permissions, interrupted assignment recovery and leave/reaccept. A
separate native-column attachment/checksum/ownership/cascade fixture remains open.
Neither local tests nor host compilation closes these rows. Mandatory v1 data
migration and beta compatibility remain separate release requirements.
