# GraphEvo — istruzioni per agenti IA

Questo file è il punto di ingresso operativo per gli agenti che lavorano sul
repository. Prima di modificare il codice, leggere il `README.md` per il quadro
generale e consultare la documentazione specifica in `docs/`.

## Obiettivo della libreria

GraphEvo è una libreria Swift basata su Core Data. Espone un modello a grafo:

- `Graph` rappresenta uno store aperto e il suo contesto Core Data;
- `Node` è la base comune degli oggetti pubblici;
- `Entity` rappresenta un oggetto di dominio;
- `Relationship` collega un subject a un object;
- `Action` rappresenta un’azione con subjects e objects;
- `Search` esegue query;
- `Watch` osserva cambiamenti locali e remoti.

Il riferimento completo alle API pubbliche è in
[`docs/api/public-api.md`](docs/api/public-api.md).

## Mappa del repository

| Percorso | Responsabilità |
|---|---|
| `Sources/GraphEvo/Graph.swift` | Apertura del graph, readiness, contesto e delegati |
| `Sources/GraphEvo/Node.swift` | Proprietà comuni, tag, gruppi e cancellazione |
| `Sources/GraphEvo/Entity.swift` | Entità e accesso a relazioni/azioni |
| `Sources/GraphEvo/Relationship.swift` | Relazioni orientate |
| `Sources/GraphEvo/Action.swift` | Azioni e relativi soggetti/oggetti |
| `Sources/GraphEvo/Search.swift` | Query tipizzate |
| `Sources/GraphEvo/Predicate.swift` | Costruzione dei filtri |
| `Sources/GraphEvo/Watch.swift` | Osservazione dei cambiamenti |
| `Sources/GraphEvo/Persistence/` | Configurazione, store, metadati e contesti |
| `Sources/GraphEvo/Migration/` | Migrazioni, ledger, backup e logging |
| `Sources/GraphEvo/Tools/` | Merge, deduplicazione e strumenti diagnostici |
| `Sources/GraphEvo/Transformer/` | Codifica sicura di valori eterogenei |
| `Tests/GraphEvoTests/` | Test funzionali e regressioni |

## Regole architetturali

1. Usare le facciate pubbliche `Entity`, `Relationship` e `Action`. Non creare o
   manipolare direttamente le classi Core Data `Managed*`, che sono dettagli
   interni dell’implementazione.
2. Ogni oggetto del dominio deve appartenere al `Graph` corretto. Non combinare
   `Search` costruite su graph differenti.
3. Dopo modifiche ai dati chiamare `graph.sync()` quando è necessario rendere
   persistente il contesto.
4. Usare `whenReady` quando il codice deve distinguere chiaramente tra graph
   pronto e apertura fallita.
5. Non aggiungere migrazioni automatiche per store incompatibili: GraphEvo deve
   lasciare invariati file e percorso e segnalare `incompatibleStore`.
6. Conservare il comportamento pubblico esistente e aggiornare i test quando
   si modifica un contratto.

## Configurazione degli store e URL

`GraphStoreConfiguration.location` può indicare una directory o un file SQLite.
È considerata una location esplicita quando l’estensione è `.sqlite`.

- Directory: GraphEvo costruisce `GraphEvo_<name>.sqlite` dentro la directory.
- File `.sqlite`: il percorso completo è autorevole e non viene riscritto.
- `resolvedLocation`: directory effettiva usata per la risoluzione.
- `storeURL`: percorso canonico calcolato dalla configurazione.
- `resolvedStoreURL`: percorso realmente aperto, incluso l’eventuale riuso di
  uno store legacy.
- `appGroupIdentifier`: può sostituire la directory per una configurazione
  basata su directory; non sposta un file `.sqlite` esplicito.
- `.inMemory`: usa un database temporaneo; le URL vengono calcolate ma non
  identificano un file persistente.

Quando si modifica questa logica verificare almeno: directory nuova, file
esplicito esistente, file esplicito non ancora creato, App Group, store legacy,
backend in-memory e nomi con estensione maiuscola/minuscola.

## API operative essenziali

### Apertura e salvataggio

```swift
var config = GraphStoreConfiguration()
config.name = "Main"
let graph = Graph(configuration: config)

graph.whenReady { result in
    switch result {
    case .success(let graph): graph.sync()
    case .failure(let error): print(error.localizedDescription)
    }
}
```

API da preferire:

- `Graph(configuration:migrationEnabled:)` per configurazioni esplicite;
- `Graph(storeURL:backend:migrationEnabled:)` quando il chiamante possiede già
  una directory o un file preciso;
- `whenReady` per il risultato di apertura;
- `sync` per il salvataggio sincrono e `async` per quello asincrono;
- `newBackgroundContext()` per lavori Core Data in background.

### Creazione e modifica dei dati

```swift
let user = Entity("User", graph: graph)
user["email"] = "ada@example.com"
user.add(tags: "active")

let note = Entity("Note", graph: graph)
user.is(relationship: "writes").of(note)
graph.sync()
```

Le proprietà dei nodi sono dinamiche e di tipo `Any?`. Per valori complessi
usare i transformer/coder pubblici documentati nell’API reference.

### Query

```swift
let activeUsers = Search<Entity>(graph: graph)
    .where(.type("User"))
    .where(.has(tags: "active"))
    .sync()
```

Attenzione: chiamate successive a `where` vengono combinate con OR nel codice
attuale. Se serve un’espressione composta esplicita, costruire un `Predicate`
con `&&`, `||` e `!` prima di passarlo alla ricerca.

### Watcher

Un watcher è inizialmente fermo. Configurare il filtro e il delegate, quindi
chiamare `resume()`. Usare `pause()` per sospenderlo e `clear()` per rimuovere
il filtro. I callback distinguono `GraphSource.local` e `GraphSource.cloud`.

## CloudKit e Persistent History

La precedenza per il container identifier è:

1. `configuration.cloudKitContainerIdentifier`;
2. `Graph.cloudKitContainerIdentifier`;
3. Info.plist `GraphCloudKitContainerIdentifier`.

Senza identifier il graph resta locale. Se CloudKit non è disponibile, GraphEvo
può emettere un warning e usare un fallback locale.

Per il ciclo dei cambiamenti remoti chiamare
`ph_prepareOnLaunchAfterContainerReady()` dopo che il container è pronto.
Persistent History usa un token persistito e filtra le transazioni autoriali
locali per evitare callback duplicate sul dispositivo originario.

## Migrazioni

Registrare le migrazioni prima di creare o aprire il graph:

```swift
GraphMigrationManager.registerMigration(MyMigration())
```

Le fasi sono `.preInit`, `.postInit`, `.postMigration` e `.ready`. Una migrazione
deve dichiarare `id`, implementare `handlePhase`, indicare con `needsRun` se deve
essere eseguita e chiamare la completion con `GraphMigrationResult`.

Prima di trasformare uno store usare `MigrationBackupManager`. Il backup di uno
store include `.sqlite` e, se presenti, i file `.sqlite-wal` e `.sqlite-shm`.

## Workflow per le modifiche

1. Identificare il modulo responsabile e leggere i test correlati.
2. Verificare se la modifica cambia un’API pubblica, una URL persistente, il
   modello Core Data, la sincronizzazione o il comportamento dei watcher.
3. Implementare il cambiamento mantenendo compatibilità e naming esistenti.
4. Aggiungere o aggiornare test di regressione.
5. Aggiornare il documento API e la guida tematica coinvolta.
6. Eseguire `git diff --check` e i test disponibili.
7. Riassumere chiaramente file modificati, test eseguiti e limitazioni ambientali.

## Workflow Git e pull request

Ogni modifica deve rimanere tracciata, descritta e facilmente reversibile. Non
lavorare direttamente sui branch condivisi o sui branch di release, salvo una
richiesta esplicita.

1. Partire dal branch corretto e verificare che il working tree sia pulito:

   ```bash
   git status --short --branch
   git fetch --prune
   ```

2. Creare un branch dedicato per la modifica. Usare un nome descrittivo, ad
   esempio `codex/docs-agents-workflow` o `codex/fix-store-resolution`.

   ```bash
   git switch -c codex/<descrizione-breve>
   ```

3. Tenere la modifica concentrata sullo scopo del branch. Non includere file
   estranei, formattazioni casuali o cambiamenti non spiegati.

4. Aggiornare codice, test e documentazione insieme quando fanno parte dello
   stesso comportamento. Il messaggio dei commit deve spiegare l’intento, non
   solo elencare i file, per esempio:

   ```text
   docs: document GraphStoreConfiguration URL resolution
   fix: preserve explicit SQLite store URLs
   test: cover legacy store fallback
   ```

5. Prima di creare la PR controllare sempre:

   ```bash
   git diff --check
   git status --short --branch
   git diff --stat
   swift package dump-package
   swift test
   ```

   Se una verifica non può essere eseguita, descrivere il motivo nella PR e nel
   riepilogo del lavoro. Non nascondere un test fallito né alterare il codice
   solo per aggirare una limitazione dell’ambiente.

6. Pubblicare il branch e aprire una pull request verso il branch previsto. La
   PR deve contenere:

   - obiettivo e contesto della modifica;
   - comportamento precedente e comportamento nuovo;
   - elenco dei file o moduli coinvolti;
   - test eseguiti e relativi risultati;
   - eventuali rischi, limitazioni o attività successive;
   - indicazione della documentazione aggiornata.

7. Attendere la revisione e i controlli automatici prima del merge. Il merge
   deve avvenire tramite PR, così codice, discussione, verifiche e decisioni
   restano associati allo stesso cambiamento.

8. Per correggere una modifica già tracciata, aggiungere un nuovo commit o
   aggiornare la PR. Evitare di riscrivere la storia dei branch condivisi.
   Per annullare una modifica già mergiata, preferire un commit di revert: il
   cambiamento originale e la sua inversione restano entrambi visibili.

9. Non usare comandi distruttivi come `git reset --hard` o `git checkout --`
   senza una richiesta esplicita e senza aver verificato cosa verrebbe perso.
   Prima di ogni operazione potenzialmente distruttiva controllare il target
   esatto e creare, se necessario, una copia o un commit di salvataggio.

## Verifiche consigliate

```bash
git diff --check
swift package dump-package
swift test
```

Il package dichiara iOS 16+ e macOS 12+, ma alcune parti importano framework
Apple disponibili solo nel relativo SDK. Se `swift test` fallisce sul runner
macOS per `UIKit` o `PDFKit`, riportare il limite senza modificare gli import
solo per far passare un test locale non rappresentativo.

## Errori da evitare

- Non usare `Graph(name:)`: il costruttore pubblico richiede una configurazione
  oppure una `storeURL`.
- Non assumere che `location` sia sempre il file SQLite finale.
- Non usare `storeURL` quando serve sapere quale file legacy verrà realmente
  aperto: usare `resolvedStoreURL`.
- Non modificare direttamente classi `Managed*` per correggere un comportamento
  della API pubblica.
- Non considerare `GraphReadiness` come risultato di una migrazione applicativa:
  la migrazione comunica errori tramite `GraphEvent`.
- Non introdurre sincronizzazione CloudKit senza gestire fallback, eventi e
  Persistent History.
- Non committare file di store, token o log generati dai test.

## Aggiornamento della documentazione

Quando cambia una firma pubblica, aggiornare sempre
[`docs/api/public-api.md`](docs/api/public-api.md). Quando cambia il flusso
operativo, aggiornare questo file e la guida tematica corrispondente in `docs/`.
Il `README.md` deve rimanere introduttivo: non duplicare lì la reference completa.
