# Related-query cost and attachment limits on iPhone XR

The local Release fixture contains 2,000 application entities, one related node
and one directed relationship. A second fixture adds four 10 MiB attachments.
The baseline is integrated revision `2e71189a`. The iPhone XR ran iOS 18.7.11.
Times below are medians of four repetitions after the first invocation unless
otherwise stated.

| Related query | No attachments | Four attachments |
|---|---:|---:|
| Baseline, default 100,000 steps | Refused | Refused |
| Temporary topology prototype | 99.8 ms | 100.6 ms |
| Alpha evaluator with per-direction lookup | 99.7 ms | 100.9 ms |
| Native fetch prototype | 7.3 ms | 7.5 ms |

The baseline completed on the attachment-free fixture at 317.1 ms with a
separate diagnostic budget. It charged 4,012,026 steps. The topology prototype
charged 10,029 and 10,046 steps in the two fixtures and returned the expected
record with the normal budget. The native prototype fetched a destination tag,
projected the subject of the matching relationship and materialized one complete
record. Its scope was a single ASCII tag and direct relationship. Broader
native execution and any associated public API decisions are beta development.

The alpha evaluator uses temporary per-direction lookups within its existing
local snapshot. Its physical rerun returned the same node and charged 10,029
and 10,046 steps, respectively. The candidate allowance, default 32 MiB charged property budget
and default 100,000 logical steps continue to describe work admission. These
observations do not establish a general maximum graph size or latency guarantee.

The current library attachment envelope is 10 MiB per file. On the four-file
fixture, listing metadata took 611 ms. Independent samples of the underlying
paths measured about 320 ms for the identity audit, 299 ms for metadata projection
and 4 ms for owner lookup. The initial matched-device run measured the list at
600 ms on XR and 228 ms on iPadOS 27.0. A local 10 MiB replacement was sampled
once per device and increased process resident memory by about 43 MiB on XR
and 52 MiB on iPad. Metadata listing scope and replacement costs remain PA05 work.
The next metadata measurement compares the full listing path against a fetch
scoped to attachment rows, with owner and result validation and legacy file
fallback covered separately.

These are synthetic local measurements, with uncontrolled OS caches. They
do not include network transfer or establish maximum device memory use.
