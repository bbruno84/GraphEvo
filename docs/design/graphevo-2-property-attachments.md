# GraphEvo 2 — properties and attachments

Status: alpha increment integrates through
[PR #191](https://github.com/bbruno84/GraphEvo/pull/191); review and acceptance
evidence are recorded in the development status page. This contract supersedes binary GraphValue
properties and the former 10 MiB ordinary attachment admission.

## Consumer contract

Scalars and supported recursive arrays/string-keyed dictionaries remain
properties. `Data` and generic Codable values use keyed attachments. The model
protocol remains unchanged: consumers map fields through `GraphRecord.properties`
and `GraphRecord.attachments`, and read them through `value(for:as:)`,
`attachmentData(for:)` and `attachmentValue(for:as:)`.

The library owns serialization. Codable attachments use sorted-key JSON with a
fixed codec/version; arbitrary application-selected codecs are not a public
property API. A field cannot occupy both channels. Patches explicitly set or
remove attachments and preserve every unnamed field.

Ordinary insertions and replacements reject content larger than **2 MiB**
(2,097,152 bytes), including Codable's encoded bytes. Detached construction,
reading, export and deletion do not impose that admission limit. A scalar patch
preserves an existing oversized migrated attachment. Explicitly setting that
same oversized value is a replacement and is refused. Larger new content uses
the existing File primitive.

## Native persistence and old stores

S06 (`GraphEvo.v2.schema.6`) is the coordinated ordinary/App Group profile.
S07 (`GraphEvo.v2.schema.7.local-files`) adds the existing File primitive.
Fresh factories preserve the historical S04/S05 models and hashes. Existing
S04/S05 stores are refused unchanged by current contexts. There is no alpha
store upgrade or relabelling. The historical S04-to-S05 helper is package-only.

Attachment rows retain their logical identity and exactly one application-node
owner. Fixed optional native owner/key/metadata/content attributes replace
binary application properties. Content permits Core Data external binary
storage; Core Data owns that lifecycle. The graph/owner/key compound index
supports materialization without scanning unrelated bodies. Owner/key survive
native deletion history. Technical attachment rows still count toward native
candidate and synchronization inventories. Full record materialization charges
attachment bytes; metadata and query projections avoid content faults.

S06/S07 reads retain a finite Foundation read intent from before pinning the SQL
generation through copying external binary content and resetting the context.
A pinned SQL generation alone does not retain an external binary revision after
a concurrent replacement. The read intent uses the existing store coordinator
without associating the writer presenter, so the same presenter cannot bypass
an active reader. Historical schema profiles retain their existing behavior.
Synchronous read bodies must finish before a waiting writer can proceed.
Lifetime presentation watches the stable `.owners-v1` child directory while
finite intents continue to coordinate the same canonical root. Parent deletion
still consults the descendant presenter. Operations, copies and claim cleanup
must use `coordinationDirectory`, not the presentation URL. This avoids redundant
same-item presenter handoffs without changing exclusion or persisted formats;
see the [cost investigation](results/initial-publication-cost-2026-11-08.md).
`withFileURL` retains normal store admission but reads native File metadata without
the binary grant; its immutable revision remains protected by the existing
per-file Foundation intent through the callback.
Metadata listing projects only fixed metadata fields; pending mutations use the
confined session view. Listing does not certify content availability.

## Migration and synchronization

V1 conversion operates on the protected native copy. Every recoverable Data
property becomes an attachment with its original owner and key, even above
2 MiB. The library never sniffs its application meaning. Supported wrapped
collections become properties. Mixed binary collections and opaque wrappers
preserve the entire property through a legacy archive attachment. The source
logical fingerprint includes byte-exact content and old detail versions.
Attachment insertion and removal of the old property share the native batch
commit; resume never needs to replay a committed extraction.

The property codec is version 3, ordinary cloud nodes use format 5, attachments
use format 6, and File retains format 4. The graph descriptor uses format 3 with
an explicit File capability. The initial contract used session format 10; ordinary private discovery advances
it to format 11. Transport journal format 4 and the current session profile
refuse old state without erasing or resetting it. Asset references use format 2.
CKAsset bytes remain outside CloudKit record/request payload sizing. Existing
Apple request/record budgets remain unchanged. A single migrated attachment
larger than the 32 MiB preparation window is admitted alone rather than stalled.
SDK attachment URLs are copied into the durable spool before their callback
scope ends; they are not retained as permanent content locations. Out-of-order
attachments stay in the inbox until their owner is available, without hiding
later owner events.

Files retain their schema fields, immutable revisions, scoped URLs, synchronization
and reclamation behavior. No on-demand download or progress API is introduced.
