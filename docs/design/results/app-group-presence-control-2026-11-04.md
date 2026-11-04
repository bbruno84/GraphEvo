# App Group coordination — physical presence-lock control

2026-11-04. Bounded private experiment L on iPad13,18 / iPadOS 27.0
(24A437), with independent application and WidgetKit extension processes.
This records experimental evidence; it does not change the runtime or close PA02.
The target contract covers concurrent App Group processes generally; app/widget
is the concrete topology exercised here.

## Scope and causal comparison

The private fixture uses a real provisioned App Group and the S04 coordinated
local store. Its operation-scoped writer prototype uses NSFileCoordinator;
bootstrap and the native owner lifecycle remain separate boundaries. The
historical K macOS comparison and original signed L baseline are preserved.
The private library copy starts from `6dc37bbe37b9447f668f3e8b6b0a1b23677079e4`;
this is not a trial of the later H02 correction pins.
Private binaries, profiles, native stores, journals and crash reports remain
outside the repository. No CloudKit account or session participates in this test.

The original baseline retained a shared owners flock for each native owner's
lifetime. Both application and widget were terminated with RUNNINGBOARD
0xdead10cc when they became suspendible. Foreground write/read and normal close
worked. A source-reviewed control then kept the same verified sidecar descriptor
open while skipping only that shared flock. Exclusive ownership and destructive
maintenance were explicitly refused in this fd-only control; it is not a safe
replacement for the shipping protocol.

| Control | Observation |
| --- | --- |
| Retained shared presence flock | Application and widget terminated with original 0xdead10cc reports. |
| Retained descriptor, no shared presence flock | Same application and widget processes survived Home/foreground transitions. Widget changed 0 to 1; independent application read 1 and two records. Application changed 1 to 2; independent widget read 2 and three records. |
| Instrumented shared-flock repeat, fresh fixture | Both bootstrap writer locks were logged acquired and released; the lifetime owners flock remained. Both processes again terminated with 0xdead10cc. |
| Shared-flock normal close before Home | Application retained its process after native owner close and presence release. |
| Second fd-only fresh fixture | Application/widget processes survived again; widget wrote 1 and the application independently validated 1 and two records. Both owners closed normally. |

The matched repeat strongly attributes this observed termination to the retained
presence flock, separately from short Apple-coordinated writes. Process survival
and exact values were checked independently; a retained readiness acknowledgement
alone was not treated as liveness. The sequence does not certify that iOS entered
a particular suspended state, unlimited execution, assertion expiry or long writes.

Apple DTS states that file locks must be released before a process becomes
eligible for suspension, in a discussion containing an App Group shared-flock
reproducer ([Apple Developer Forums](https://developer.apple.com/forums/thread/655225)).
That historical explanation supports the interpretation; the physical reports
above establish the behavior on the tested iPad. This result does not establish
the cause of any earlier H02 app restart in its separate private container.

## Consequence for the selected protocol

The [controlled-store contract](../graphevo-2-controlled-store-access.md) retains
presence until native detachment to reject destructive maintenance while any
peer owns the store. Removing that lock without a replacement would discard
that guarantee. The fd-only control therefore cannot ship. The runtime remains
unchanged while a lifecycle-compatible exclusion contract is selected and tested.

Operation-scoped NSFileCoordinator remains a candidate for cooperating writers.
It is not evidence that a lifetime coordinator accessor is safe, that access can
continue after an accessor returns, or that mixed Apple/flock protocols coordinate.
Bootstrap, asynchronous native callbacks, prepared workspaces, maintenance,
account/session/catalog locks and cancellation still need explicit coverage.
No persistent command queue or delivery acknowledgement is implied.

Apple documents background-task handling for granted coordination requests and
requires active file presenters to be removed for background eligibility
([NSFileCoordinator](https://developer.apple.com/documentation/Foundation/NSFileCoordinator?changes=_3),
[NSFilePresenter](https://developer.apple.com/documentation/foundation/nsfilepresenter?changes=_2)).
A presenter can cooperate with an active writer, but is not by itself a persistent
presence lease for suspended peers. Any presenter-based design must account for
that lifecycle and for native detachment before replacement/deletion; it remains
an unimplemented candidate, not a demonstrated solution.

## Open acceptance

Retain PA02 as open. Establish presence/destructive-operation exclusion through
background eligibility without relying on an indefinite lock or background
assertion, then test first launch, migration, interrupted/failed detachment,
independent processes, read/write roles and the selected synchronization owner.
The physical control validates short local round trips on one device only.
It does not accept CloudKit delivery, attachments, other OS versions, long-hold
or expiry behavior, production durability, or malicious/external writers.

## Retained private evidence identity

The local report `Evidence/PRESENCE-CAUSAL-RESULT.md` has SHA-256
`8fe7c55620ed3d1e0b37d767ed28ce43701fa57b6c68969aedca3e0ccec23709`.
The final manifest `Evidence/presence-final-checksums.json` has SHA-256
`ed3dc19947aaa76ea162702b836b0a32a0532c04ef9fbd0b5c64342f1162bbf4`.
The retained `verify_physical_presence.py` passes against saved events, native
readback, expected PIDs, all four original OS termination reports and normal-close
ordering. No generated stores, journals, reports or signed products are committed.
The fd-only background/foreground notification intervals were 52.559 and 28.990
seconds; the closed-SH control interval was 24.498 seconds. These intervals do not
establish an OS suspended state, background assertion expiry or concurrent writes.
