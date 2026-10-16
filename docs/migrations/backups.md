# Backup and restore

`MigrationBackupManager` creates recoverable copies before a migration or
merge. A backup is part of the safety procedure, not merely a debugging tool.

## Back up a store

```swift
let storeConfiguration = try configuration.resolvingEnvironment()
let result = try MigrationBackupManager.backupStore(
    at: storeConfiguration.resolvedStoreURL,
    migrationID: "add-note-status"
)

print(result.folderURL)
```

For an SQLite store, the main file and, when present, `.sqlite-wal` and
`.sqlite-shm` files are copied. An overload accepts `configuration` and
`migration`, deriving the root from the migration itself.

Resolve the environment before selecting a URL so a Development backup targets
the actual `-dev.sqlite` file. For an already initialized graph, its
`configuration` is normalized. Stop all writers and close the store before
copying its SQLite family: this helper copies files and does not coordinate a
consistent snapshot of a live database.

## Back up one file

```swift
try MigrationBackupManager.backupFile(
    at: baselineURL,
    migrationID: "import-baseline"
)
```

This is useful for auxiliary files such as baselines, archives, or migration
resources.

## Conflict policy

- `.duplicate`: create a new suffixed folder; this is the safest default;
- `.skip`: reuse the existing backup;
- `.overwrite`: remove and recreate the previous folder.

Use `.overwrite` only after verifying the target and intentionally accepting the
loss of the previous copy.

## Descriptor

Each backup produces a `BackupDescriptor` with migration ID, label, original
path, date, and file list. The descriptor is saved as `backup-info.json`.

## Find and restore

```swift
let backups = try MigrationBackupManager.findBackupsForStore(
    migrationID: "add-note-status",
    storeURL: storeConfiguration.resolvedStoreURL
)

if let latest = backups.last {
    try MigrationBackupManager.restoreToOriginalLocation(
        descriptor: latest.descriptor,
        from: latest.folderURL
    )
}
```

Restore overwrites existing files by default. Pass `overwriteExisting: false`
to leave existing files untouched. Restore only while the store is closed and
all writers are stopped; never replace a live SQLite store underneath a Graph.
