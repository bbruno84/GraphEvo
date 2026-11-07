# File CloudKit private checkpoint on iPad

Date: 2026-11-07, Europe/Rome.

A disposable signed Release host exercised the File-aware public context
on a physical iPad, using the configured CloudKit Development container.
It created a synthetic private zone and used sequential account sessions
for separate owner and peer SQLite stores. The fixture contained a 25 MiB
File, a document entity, a relationship to the File, a tag and a group.

The owner imported the source through `GraphStore.importFile`, connected
through `GraphContext.localFiles().connectCloud(using:)`, bound the private
zone and completed native sends. It then closed the graph and connection.

An independently created empty SQLite replica used a distinct session
directory. It fetched and applied the native CloudKit records and
verified the exact File ID, fixed metadata, SHA-256, relationship endpoint,
tag and group.

After closing the peer, a new owner context reopened the original store,
replaced the content with a different 25 MiB source, reclaimed the retired
permanent revision and sent the replacement. A new peer context reopened
the existing peer store and received the exact replacement revision and
digest.

The host produced a passed report with all three checks. Private generated
stores, account/session documents, SDK records and device logs remain
outside the repository.

This checkpoint establishes private delivery and sequential independent
replica recovery on one physical device. It does not establish cross-account
sharing, concurrent physical devices, transfer interruption or 50 GB device
capacity.
