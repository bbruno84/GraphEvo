# MF02 — compressed GraphEvo Backup packages

Status: package-only baseline integrated through #121 into `codex/graphevo-2`,
developed on `codex/v2-compressed-backups` directly from #120 (`2009582`). No schema, record wire format or cloud
session change. This extends [MF01](graphevo-2-local-maintenance.md).
Original package implementation/measurement source is `3e509f0`.
Delivery: [PR #121](https://github.com/bbruno84/GraphEvo/pull/121). The
[review/correction](results/backup-packages-review-2026-11-01.md) closes one P2
in legacy import preflight at `8bf64b0`. The maintainer authorized continuing
through CI and merge on success after corrective review. The
[combined macOS/iOS checkpoint](https://github.com/bbruno84/GraphEvo/actions/runs/41289164075)
passes on `89644e1`; final integration-status changes are documentation-only.

## Package and discovery

The maintainer selected **`.geb`** (GraphEvo Backup). Both completed local backups
and exported files use this extension and the same single-file representation.
The filesystem and each package's manifest remain authoritative; no registration
database is required. Renamed/copied packages are discovered by extension and
validated bounded headers. Legacy MF01 directories remain readable/verifiable
and exportable; no implicit rewrite occurs. Unrelated files are ignored.

Listing reads only the header and manifest. It does not decompress the payload
or certify file/body integrity. Full verification and restore also decompress,
check every file and reopen the native graph on a disposable copy. Corrupt
recognized packages report errors rather than silently disappearing.

## Container v1

All integer fields are unsigned big-endian. The 64-byte header contains:

| Offset | Bytes | Meaning |
|---|---|---|
| 0 | 8 | ASCII `GEBACKUP` |
| 8 | 4 | Container version, `1` |
| 12 | 4 | Codec, `1` = raw DEFLATE |
| 16 | 8 | Manifest JSON byte length, at most 4 MiB |
| 24 | 8 | Compressed payload byte length |
| 32 | 32 | SHA-256 of manifest JSON |

The manifest follows the header, then one raw DEFLATE stream. Its decompressed
bytes concatenate the files in sorted manifest order; declared sizes define file
boundaries, including empty files. There is no second archive pathname/link
language to interpret. Format-1 manifest fields retain graph/native-store IDs,
schema, reason, date, relative file paths, sizes and uncompressed SHA-256 values.
Package integrity checks are not authentication or encryption.

Only relative `payload/` and `artifacts/` files are allowed, with existing
ownership/path/depth limits. Extraction creates regular files exclusively in an
owned empty stage, rejects collisions, counts implied directories and never
extracts links. Declared expansion must fit the byte/file limits before decoding;
actual output cannot exceed declared inventory. Require an end marker and exact
compressed-input consumption; reject truncated, appended and concatenated streams.
The complete file length must match its header. Default package bytes are capped
at 65 GiB, separately from the existing 64 GiB expanded-byte cap.

The codec uses SDK-provided **zlib**, level 5, a 32 KiB window and 256 KiB I/O
buffers with at most two input chunks of lookahead. It runs in an owned detached
worker whose cancellation is forwarded and awaited. Native graph validation
retains MF01's existing whole-inventory costs; the streaming codec is not a total
process-memory or temporary-space guarantee. No third-party source or package
dependency is added. The [zlib manual](https://zlib.net/manual.html) defines raw
DEFLATE, stream consumption and licensing. No zlib implementation is redistributed.

Initial local synthetic comparisons favored zlib over LZFSE for incompressible
data; repetitive metadata compressed strongly with either. The Apple Compression
prototype admitted trailing bytes in a reframed malformed-stream test, so the
implementation uses zlib's explicit stream-end/input accounting. These are
bounded implementation observations, not production/media performance acceptance.

## Capture, publication and cancellation

ContextManager captures graph-specific recovery evidence and copies the coherent
native store under MF01's graph/cloud reservations. Once native copying finishes,
it releases only its own holds; ordinary graph activity can resume while the
immutable copy is inventoried, compressed and verified. A preexisting/concurrent
manual pause remains paused. The retained graph lease protects coordinator
lifetime, not an extended write restriction.

The final `.geb` is published by same-volume rename only after verification.
Compression or verification failure/cancellation removes only owned unpublished
stages and preserves the original graph/previous backups. A crash can leave an
MF01 ownership-marked stage; existing incomplete-stage cleanup recovers it.
This is atomic package visibility and coherent source capture, not a power-loss
durability or atomic SQLite/JSON/cloud snapshot certificate.

## Export, import and restoration

- `backups.export(at:to:) async` verifies the source, copies its existing compressed
  representation to an owned stage, verifies and publishes a new `.geb`. It does
  not snapshot the live graph or recompress an existing package. Legacy directory
  export performs compression. Existing destinations and paths inside the source
  are refused before directory creation, including aliases/missing descendants.
- `backups.importBackup(at:in:) async` verifies and copies a package into the chosen
  backup collection using its original backup ID. Duplicate destinations are
  refused without replacement. The recipient can discover, verify and materialize
  the complete backup without the originating manager or original sandbox path.
- `backups.restore(at:to:) async` returns `GraphRestoredBackup`, a new empty local
  directory with `storeURL`. `GraphBackup.url` identifies the immutable `.geb` or
  legacy directory; a compressed package does not pretend to have a SQLite URL.
- Retention ownership remains durable local collection metadata. Export/import
  do not copy a migration's local retention owners into another collection.

Import into a **backup collection** is distinct from activating an application
graph. Neither import nor restore registers a graph, starts sync, changes another
graph or adopts old sharing/account/transport state. Same-identity recovery keeps
its original metadata quarantined pending explicit activation. Independent
cross-user graph adoption still requires fresh graph/cloud ownership, reference
remapping and the migration executor's activation/reconciliation contract; this
candidate does not silently authorize it. Opaque consumer properties cannot be
automatically interpreted as library references. File-provider/UI coordination,
UTType registration in a host app and in-place/cloud rollback remain separate.

## Validation and workflow

Exercise native content/PH round-trip, reason/discovery, byte-identical export,
independent-manager import, duplicate/occupied destinations, legacy export,
corruption and hostile framing/paths/expansion, retention and cancellation.
Keep synthetic desktop compression measurements separate from real-device,
production-scale and already-compressed media acceptance. No container reset or
physical probe is required to manufacture package-only evidence.
The [MF02 results](results/backup-packages-2026-11-01.md) retain local checks,
measurements, failed prototype behavior and bidirectional macOS/iOS Simulator
package recovery, without claiming independent-user graph activation.

API, status and post-alpha gates are updated in the direct #121 delivery to
`codex/graphevo-2`. Review/corrections precede remote CI and authorized merge;
no CI was requested during implementation. Measurements/laboratories stay local.
