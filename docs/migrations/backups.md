# Backup e ripristino

`MigrationBackupManager` crea copie recuperabili prima di una migrazione o di
un’operazione di merge. Il backup deve essere considerato parte della procedura
di sicurezza, non solo uno strumento di debug.

## Backup di uno store

```swift
let result = try MigrationBackupManager.backupStore(
    at: configuration.resolvedStoreURL,
    migrationID: "add-note-status"
)

print(result.folderURL)
```

Per uno store SQLite vengono copiati il file principale e, se presenti, i file
`.sqlite-wal` e `.sqlite-shm`.

È disponibile anche un overload che riceve `configuration` e `migration`, così
la root viene ricavata dalla migrazione stessa.

## Backup di un singolo file

```swift
try MigrationBackupManager.backupFile(
    at: baselineURL,
    migrationID: "import-baseline"
)
```

È utile per file ausiliari come baseline, archivi o risorse di migrazione.

## Policy di conflitto

- `.duplicate`: crea una nuova cartella con suffisso; è il default più sicuro;
- `.skip`: riusa il backup esistente;
- `.overwrite`: rimuove la cartella precedente e la ricrea.

Usare `.overwrite` solo quando il target è stato verificato e la perdita della
copia precedente è intenzionale.

## Descriptor

Ogni backup produce un `BackupDescriptor` con migration ID, label, percorso
originale, data e lista dei file. Il descriptor viene salvato in
`backup-info.json`.

## Cercare e ripristinare

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

Il ripristino sovrascrive per default i file esistenti. Passare
`overwriteExisting: false` per lasciare intatti i file già presenti.
