# Initial publication cost investigation — 2026-11-08

Scope: the follow-up to PR #191 on `codex/v2-property-attachment-contract`,
starting from `4ff22b6a`. The 215-second functional result was not an acceptable
performance conclusion. This investigation measures and corrects local costs
without weakening native ownership or data checks.

## What the fixture measures

The fixture creates **36 strings of 720,000 UTF-8 bytes**, or 25,920,000 raw
bytes, alongside its small converted source records and attachments. These are
large scalar properties, not a 26 MB File or CKAsset. It prepares an immutable
initial seed, publishes through a synthetic in-process CloudKit service, then
creates a genuinely empty SQLite replica and verifies the recovered values.
There is no network transfer to Apple in these timings.

Each property is encoded into the versioned value envelope and then represented
as Data in the cloud body. Base64 therefore expands the large-property body to
about 34.6 MB overall. The unchanged record/request budgets allow roughly one
large record per request. The profiles record 38 advancement calls, 37 native
receipt callbacks and 38 import callbacks. This is repeated local work, not a
single sequential copy of 26 MB.

Environment: Apple Silicon macOS 27.0.1 (26A434), Apple Swift 6.4.2. Fresh fixture
UUIDs and directories are allocated for every run. Baseline Release uses `-O`
and testing visibility, without defining DEBUG. Logs and stores remain external.

## Matched results

| Phase | Baseline Debug | Baseline Release | Corrected Release |
|---|---:|---:|---:|
| Create/convert fixture and insert large properties | 1.85 s | 1.44 s | 1.00 s |
| Prepare seed | 2.69 s | 2.35 s | 0.47 s |
| Publish and commit confirmations, 38 advancements | 136.69 s | 111.54 s | 7.55 s |
| Open/import independent empty replica | 71.17 s | 57.19 s | 3.41 s |
| Verify recovered records | 1.84 s | 1.20 s | 0.15 s |
| Complete test, including closing | **214.25 s** | **173.74 s** | **12.59 s** |

A second corrected Release run passes in **12.66 s**. The corrected shipping
fixture, without profiling wrappers, passes in **12.83 s Debug** in the full v2
profile. All original value, no-feedback, independent-replica and capacity
assertions remain. The original **two-minute guard is restored**; increasing a
deadline is not the performance fix.

### Foreign-string scanning

Core Data returns `__NSCFString` storage. The native scalar decoder previously
checked for an embedded zero through Swift's UTF-8 view twice on each full read.
The sync resolver also performs complete graph validation after receipt/import
batches, multiplying those scans across the growing or unchanged graph.

CPU samples in both configurations point into these checks. A 20-iteration
native-string control measures 0.331 s for Swift UTF-8 search, 0.304 s for
`String.range`, and 0.033 s for direct `NSString.range`. The production change
uses Foundation's literal NSString search and performs the same representation
check once. It does not remove null-character validation or change storage.
Tests cover empty strings, a literal backslash-zero, Unicode, actual zero
positions and rejection of a malformed inline native value.

With only this correction the complete Debug fixture drops to **142.74 s**.
Native receipt callback totals fall from 46.82 to 4.28 s; native import callback
totals fall from 26.01 to 2.64 s. That improvement still leaves excessive cost.

### Presenter handoff

Temporary payload-free timing around Foundation access finds **15.38 s waiting
for 98 reads** in the first six-advance cut, versus only 0.40 s executing those
read bodies. Slow reads cluster at roughly 0.53 s immediately after writes.

A standalone Foundation control reproduces the delay with **zero payload bytes
and no Core Data**: four empty write/read pairs take **2.149 s** when the presenter
and coordination target are the same directory. Presenting a child registration
directory while coordinating on the parent takes **0.015 s**. Both configurations
refuse parent deletion while registered and admit it after unregistering.
The exact delay is an observation on this OS, not an Apple timing guarantee.

The runtime now presents its existing stable `.owners-v1` directory. Ordinary
read/write intents still target the **same canonical coordination root**. The
presenter's native lifetime, persistent generation records, root identity checks,
writer/read exclusion, cancellation and terminal cleanup remain. Copy and claim
cleanup explicitly use the coordination root rather than the presentation URL.
Presenting the directory also keeps its identity stable when an individual
registration is atomically replaced during retirement.

This uses Apple's documented distinction: ordinary directory access does not
coordinate descendants, whereas deletion/moving/replacement access does. Parent
deletion therefore still consults the descendant lifetime presenter. See
[Foundation coordination semantics](https://developer.apple.com/documentation/foundation/nsfilecoordinator/coordinate(with:queue:byaccessor:)).

Controls with `withoutChanges`, different submission queues, explicit presenter
callbacks and autorelease pools did not resolve the handoff delay and are not
included. Synchronous versus asynchronous coordination and file versus directory
presentation at the same target likewise retain the delay. Neither a new
advisory lock nor a polling/backoff workaround is introduced.

## Verification and limits

The corrected implementation passes **773 macOS v2 tests**: 646 store, 94 runtime
and 33 model tests. All **331 legacy tests**, both Swift 6 consumers and **197
affected iOS 18.5 Simulator tests** pass. The new scope tests prove registration
metadata replacement retains the parent-deletion fence, readers and writers
exclude each other in both orders, and queued reader cancellation does not wait
for the writer to release. Existing cold external-binary, backup, migration,
purge/refusal/recovery and attachment tests remain included.

A signed Release build on physical iPad/iPhone XR reopens the existing private
and shared replicas, verifies revision 3 raw/Codable/collection values, the
oversized migrated attachment and the File digest, then closes with receipts.
This is a physical correctness confirmation; **it is not a device throughput
measurement or a repeated first publication**.

The selected regression is corrected. Complete graph validation still repeats
between batches and wire bodies still contain base64 value envelopes. Their
cost at broader scales, representative device/Release envelopes, actual CloudKit
network latency and production source coverage remain PA05/PA06/PA08 work.
No general bandwidth, total-memory, global-convergence or beta-readiness claim
follows. No hosted CI checkpoint or merge was requested for this investigation.

Reproduction fixtures and exact build/runner notes are in
[ActivationPublicationCost](../../../Experiments/ActivationPublicationCost/README.md).
