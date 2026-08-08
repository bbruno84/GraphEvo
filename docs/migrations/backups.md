# Backup and restore

`MigrationBackupManager` creates recoverable copies before a migration or
merge. A backup is part of the safety procedure, not merely a debugging tool.

## Back up a store

```swift
let result = try MigrationBackupManager.backupStore(
    at: configuration.resolvedStoreURL,
    migrationID: "add-note-status"
)

print(result.folderURL)
```

For an SQLite store, the main file and, when present, `.sqlite-wal` and
`.sqlite-shm` files are copied. An overload accepts `configuration` and
`migration`, deriving the root from the migration itself.

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
    storeURL: configuration.resolvedStoreURL
)

if let latest = backups.last {
    try MigrationBackupManager.restoreToOriginalLocation(
        descriptor: latest.descriptor,
        from: latest.folderURL
    )
}
```

Restore overwrites existing files by default. Pass `overwriteExisting: false`
to leave existing files untouched.
