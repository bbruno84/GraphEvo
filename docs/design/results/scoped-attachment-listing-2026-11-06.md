# Scoped SQLite attachment listing and the 10 MiB envelope

A physical iPhone XR on iOS 18.7.11 ran the Release fixture with 2,000
application entities and four 10 MiB attachments. The current list took a
median of 9.4 ms across the four calls after the first, which took 10.6 ms.
The preceding unscoped run measured 618 ms on the same device and fixture.
The scoped list preserved exact results in synthetic split/legacy and
different-owner cases. Automated SQLite coverage verifies that a damaged
unrelated row is reported by the explicit integrity audit and a damaged
attachment identity fails the list.

The same implementation published four synthetic 10 MiB files to a fresh
private CloudKit Development zone on a physical iPad. Two send turns were
needed. A direct read verified each server CKAsset's size before a fresh
independent SQLite store on the same iPad fetched and imported the graph.
All four attachments matched by identity, metadata and full byte content.
The receiving store had zero outgoing changes. Publishing plus direct
server verification took about 20.6 seconds and the fresh store's fetch
plus import took about 2.0 seconds in this single run.

Local automated coverage exercises empty files, files at the 10 MiB
boundary, refusal of a replacement one byte over the boundary and preservation
of the previous file. The Release XR fixture measured one 10 MiB replacement
at 417 ms, with about 43 MiB of additional sampled resident memory. These
results establish the tested envelope on the stated fixtures. Wider media,
device, interruption and network performance remain separate acceptance work.
