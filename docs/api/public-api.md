# GraphEvo — guida alle API pubbliche

GraphEvo è una libreria Swift che offre un modo semplice per organizzare dati
collegati tra loro. Alla base utilizza Core Data e può lavorare sia con un
database locale sia con CloudKit.

Questo documento è una guida pratica alle API pubbliche: spiega a cosa servono
le varie parti della libreria, mostra gli usi più comuni e riporta le firme
necessarie per consultazione automatica o generazione di codice.

Le informazioni sono state ricavate dal codice presente in `Sources/GraphEvo`,
dal `Package.swift` e dai test del repository.

## 1. Identità del modulo

- Modulo Swift Package Manager: `GraphEvo`
- Prodotto: libreria `GraphEvo`
- Piattaforme dichiarate: iOS 16+, macOS 12+
- Dipendenza runtime: `ZIPFoundation` (usata dalle utility di migrazione)
- Modello dati: Core Data; supporto locale SQLite e CloudKit tramite
  `NSPersistentCloudKitContainer` quando è configurato un container.

Importazione:

```swift
import GraphEvo
```

## 2. Concetti fondamentali

Il modo più semplice per capire GraphEvo è immaginare un piccolo grafo di dati:
gli oggetti sono i nodi, mentre le relazioni e le azioni descrivono i legami
tra loro.

GraphEvo rappresenta tre tipi di nodi pubblici:

| Tipo | Significato |
|---|---|
| `Entity` | Oggetto di dominio con tipo, proprietà, tag, gruppi e relazioni/azioni |
| `Relationship` | Arco tipizzato fra una `subject` e un `object` |
| `Action` | Evento/azione tipizzata con insiemi di `subjects` e `objects` |

Tutti derivano da `Node`. In pratica, `Node` raccoglie le funzionalità comuni,
mentre `Entity`, `Relationship` e `Action` aggiungono il comportamento specifico.
Le istanze sono collegate a Core Data, ma nella maggior parte dei casi non è
necessario lavorare direttamente con gli oggetti Core Data.

### Flusso minimo

```swift
var configuration = GraphStoreConfiguration()
configuration.name = "Main"
let graph = Graph(configuration: configuration)

let user = Entity("User", graph: graph)
user["email"] = "ada@example.com"
user.add(tags: "active")

let note = Entity("Note", graph: graph)
user.relate(to: note)
graph.sync()

let users = Search<Entity>(graph: graph)
    .where(.type("User"))
    .sync()
```

> `Graph` prepara il database durante la sua inizializzazione. Per sapere con
> certezza quando il database è utilizzabile è preferibile usare `whenReady`.
> Dopo aver modificato i dati, chiamare `graph.sync()` per salvarli esplicitamente.

## 3. Persistenza e `Graph`

### `GraphStoreConfiguration`

Questa struttura raccoglie le informazioni necessarie per aprire un database:
il suo nome, dove salvarlo, quale backend utilizzare e quali versioni del modello
sono richieste. Nella maggior parte dei casi è sufficiente modificare `name` e,
se necessario, `location`.

Il campo che può creare più facilmente confusione è `location`. Non rappresenta
sempre il file SQLite finale: può indicare sia una directory dentro cui GraphEvo
deve costruire il nome del database, sia un file SQLite già preciso. La libreria
riconosce una location come file esplicito quando la sua estensione è `.sqlite`.
In tutti gli altri casi la considera una directory.

```swift
public struct GraphStoreConfiguration {
    public var name: String = "default"
    public var backend: GraphStoreBackend = .sqlite
    public var location: URL
    public var appGroupIdentifier: String?
    public var cloudKitContainerIdentifier: String?
    public var requiredGraphModelVersion: Int = 1
    public var requiredAppDataVersion: Int = 1
    public init()
}
```

Proprietà calcolate:

- `resolvedLocation`: directory effettiva in cui cercare o creare lo store.
- `storeFilename`: nome canonico, nella forma `GraphEvo_<name>.sqlite`.
- `storeURL`: URL canonico ottenuto da `location`, senza cercare file legacy.
- `route`: identificatore del percorso/backend usato internamente.
- `requiredVersions`: `Versions(graphModel:appData:)` richieste.
- `legacyStoreURLs`: elenco dei vecchi percorsi che possono essere riutilizzati.
- `resolvedStoreURL`: URL effettivo scelto dopo il controllo dei file esistenti.

```swift
public struct Versions: Equatable {
    public var graphModel: Int?
    public var appData: Int?
    public init(graphModel: Int?, appData: Int?)
}

public enum GraphStoreBackend {
    case sqlite
    case inMemory
}
```

#### Come vengono interpretate le URL

| Configurazione | `resolvedLocation` | `storeURL` | Comportamento di `resolvedStoreURL` |
|---|---|---|---|
| `location` è una directory | La directory indicata, oppure quella dell’App Group | `directory/GraphEvo_<name>.sqlite` | Usa il file canonico se esiste, altrimenti cerca i percorsi legacy |
| `location` è un file `.sqlite` | La directory che contiene il file | La stessa URL del file, senza modifiche | Restituisce sempre esattamente quel file |
| Backend `.inMemory` | Viene comunque calcolata normalmente | Viene comunque calcolata normalmente | Il backend non persiste il database su quella URL |

Esempi:

```swift
// 1. Location come directory: il file finale dipende da name.
var config = GraphStoreConfiguration()
config.name = "Main"
config.location = URL(fileURLWithPath: "/tmp/MyApp/Graph")

// storeURL / resolvedStoreURL:
// /tmp/MyApp/Graph/GraphEvo_Main.sqlite

// 2. Location come file: il percorso completo è autorevole.
config.location = URL(fileURLWithPath: "/tmp/MyApp/legacy.sqlite")

// storeURL / resolvedStoreURL:
// /tmp/MyApp/legacy.sqlite
```

Quando si costruiscono URL locali a mano, è preferibile usare
`URL(fileURLWithPath:)`: una URL `file://` identifica un percorso sul filesystem,
mentre una URL HTTP o una semplice stringa non rappresentano necessariamente un
file utilizzabile da Core Data.

#### Directory, file esplicito e App Group

Se `location` è una directory e `appGroupIdentifier` è valorizzato, GraphEvo
prova a usare la directory condivisa dell’App Group e aggiunge il proprio
percorso `CosmicMind/Graph/`. Questo è utile quando più target della stessa app,
per esempio app principale ed estensione, devono vedere lo stesso database.

Se invece `location` è un file `.sqlite`, il file esplicito ha sempre la priorità:
`appGroupIdentifier` non sposta né riscrive quel file. Questa regola evita che
passare un file preciso a `Graph(storeURL:)` produca un database diverso in base
alla configurazione dell’App Group.

Il fatto che una URL termini con `/` non è ciò che decide il comportamento. La
decisione si basa sull’estensione `.sqlite`; per chiarezza, quando si indica una
directory è consigliabile passare una URL creata con `isDirectory: true` dove
appropriato e non usare nomi di file SQLite come directory.

#### URL canonica e percorsi legacy

Per una configurazione basata su directory, GraphEvo preferisce il percorso
canonico:

```text
<directory>/GraphEvo_<name>.sqlite
```

Se questo file non esiste, controlla alcuni layout delle versioni precedenti,
tra cui:

```text
<directory>/Graph.sqlite
<directory>/Local/<name>/GraphEvo_<name>.sqlite
<directory>/Cloud/<name>/GraphEvo_<name>.sqlite
```

La scelta del percorso legacy tiene conto del fatto che il graph sia configurato
con o senza CloudKit, ma mantiene anche un controllo sui percorsi alternativi.
GraphEvo riutilizza il file trovato; non lo copia automaticamente accanto al
nuovo percorso canonico. Per questo `resolvedStoreURL` è la proprietà da usare
quando serve sapere quale file verrà realmente aperto.

Con una location che punta direttamente a un file `.sqlite`, invece, non viene
eseguita alcuna ricerca legacy: quel file è la scelta esplicita del chiamante.

#### Backend e URL

`GraphStoreBackend.sqlite` usa un file SQLite reale e quindi tutte le regole
precedenti sulle URL sono rilevanti. `GraphStoreBackend.inMemory` usa un store
temporaneo in memoria: la configurazione continua ad avere URL calcolate per
coerenza, ma non ci si deve aspettare di trovare un file persistente dopo la
chiusura del graph.

Un modello incompatibile non viene modificato automaticamente. È una scelta di
sicurezza: l’applicazione deve decidere come trasformare i propri dati, eseguire
la migrazione e poi riaprire il database sul percorso originale.

### `Graph`

`Graph` è il punto di ingresso principale della libreria. Rappresenta un database
aperto e fornisce il contesto necessario per creare oggetti, cercarli, salvarli
e ricevere notifiche sui cambiamenti.

Costruttori:

```swift
public init(configuration: GraphStoreConfiguration, migrationEnabled: Bool = true)
public convenience init(
    configuration: GraphStoreConfiguration,
    migrationEnabled: Bool = true,
    onReady completion: @escaping (Result<Graph, GraphStoreOpeningError>) -> Void
)
public convenience init(
    storeURL: URL,
    backend: GraphStoreBackend = .sqlite,
    migrationEnabled: Bool = true
)
```

Proprietà pubbliche:

- `configuration: GraphStoreConfiguration` — sola lettura dall’esterno.
- `readiness: GraphReadiness` — stato tecnico dello store/context; setter interno.
- `isReady: Bool` — `true` solo quando `readiness == .ready`.
- `name`, `route`, `location`, `type` — identificativi e percorso risolti.
- `runtimeStoreURL: URL?` — URL runtime eventualmente assegnato dalla libreria.
- `rebuildFromCloud: Bool?`, `managedObjectContext`, `storeOpeningError` — lettura
  pubblica, aggiornamento interno.
- `batchSize` — limite Core Data (`0` = nessun limite).
- `batchOffset` — offset dei risultati delle ricerche.
- `watchers: [Watcher]` — watcher registrati, aggiornamento interno.
- `cloudStatusDelegate: GraphCloudStatusDelegate?` — stato account iCloud.
- `delegate: GraphDelegate?` — contratto legacy.
- `eventDelegate: GraphEventDelegate?` — eventi diagnostici; eventi emessi prima
  dell’assegnazione vengono accodati e consegnati sul main thread.

API operative:

```swift
public static var cloudKitContainerIdentifier: String?
public func whenReady(_ completion: @escaping (Result<Graph, GraphStoreOpeningError>) -> Void)
public func newBackgroundContext() -> NSManagedObjectContext?
public func sync(_ completion: ((Bool, Error?) -> Void)? = nil)
public func async(_ completion: ((Bool, Error?) -> Void)? = nil)
public func clear(_ completion: ((Bool, Error?) -> Void)? = nil)
public func reset()
public func purgeCloudStore(completion: @escaping (Result<Void, Error>) -> Void)
```

Gli errori di validazione sono esposti come `GraphCloudPurgeError`.

Per CloudKit, GraphEvo cerca l’identificatore prima nella configurazione, poi
nell’override runtime `Graph.cloudKitContainerIdentifier` e infine in
`GraphCloudKitContainerIdentifier` dentro Info.plist. Se non trova nulla,
continua a funzionare normalmente in modalità locale.

`whenReady` completa con `.success(graph)` oppure con uno dei casi di
`GraphStoreOpeningError`. `newBackgroundContext()` restituisce `nil` prima che il
container sia disponibile; il contesto creato usa transaction author GraphEvo e
merge policy `NSMergeByPropertyObjectTrumpMergePolicy`.

`purgeCloudStore` elimina la zona Core Data CloudKit
(`com.apple.coredata.cloudkit.zone`) dal database remoto tramite
`NSPersistentCloudKitContainer`. Richiede un container CloudKit effettivamente
caricato con almeno uno store CloudKit; rifiuta configurazioni locali, fallback
locali, container non pronti e l’esecuzione durante i test. La completion
arriva solo dopo il completamento Core Data: gli errori CloudKit/Core Data sono
propagati e una risposta priva della zona purgata non è considerata successo.
GraphEvo non cancella né ricrea lo store locale. Dopo un successo l’app deve
riaprire o ricreare lo store e azzerare i token di Persistent History locali.

### Stato ed errori di apertura

```swift
public enum GraphReadiness { case initializing; case ready; case failed(GraphStoreOpeningError) }
public enum GraphStoreOpeningError: LocalizedError {
    case incompatibleStore(URL)
    case unreadableStore(URL, underlying: Error)
    case failedToLoadStore(URL, underlying: Error)
}
```

## 4. Nodi di dominio

### `Node`

`Node` è la base comune di tutti gli oggetti del grafo. Ogni nodo ha un tipo,
un identificatore, una data di creazione e può contenere proprietà libere.
Questo permette di modellare rapidamente dati diversi senza creare una classe
Swift per ogni tipo di oggetto.

```swift
public class Node: NSObject, Codable {
    public convenience init(_ type: String, graph: String)
    public convenience init(_ type: String, graph: Graph)
    public var type: String { get }
    public var id: String { get }
    public var createdDate: Date { get }
    public var tags: [String] { get }
    public var groups: [String] { get }
    public var properties: [String: Any] { get }
    public subscript(name: String) -> Any? { get set }
    public subscript(dynamicMember member: String) -> Any? { get set }
    public func delete()
}
```

I tag sono etichette brevi, utili per classificare gli oggetti; i gruppi servono
per rappresentare appartenenze. Le operazioni sono fluenti e restituiscono
`Self`, quindi possono essere concatenate:

```swift
add(tags: String...) / add(tags: [String])
has(tags: String...) -> Bool
has(tags: [String], using: SearchCondition = .and) -> Bool
remove(tags: String...) / remove(tags: [String])
toggle(tags: String...) / toggle(tags: [String])

add(to groups: String...) / add(to groups: [String])
member(of groups: String...) -> Bool
member(of groups: [String], using: SearchCondition = .and) -> Bool
remove(from groups: String...) / remove(from groups: [String])
toggle(groups: String...) / toggle(groups: [String])
```

`tags` e `groups` si comportano come insiemi: aggiungere due volte lo stesso
valore non crea duplicati. Con `.and` tutte le etichette devono essere presenti;
con `.or` ne basta una.

### `NodeClass`

```swift
public enum NodeClass: Int {
    case entity
    case relationship
    case action
}
```

Espone inoltre `NodeClass.graph` come `CodingUserInfoKey` per la codifica dei nodi.

### `Entity`

`Entity` è l’oggetto di dominio più usato. Può avere proprietà, tag e gruppi,
ma anche partecipare a relazioni e azioni. Per creare un’entità basta indicare
un tipo, ad esempio `Entity("User", graph: graph)`.

Proprietà: `managedObjectContext`, `nodeClass`, `actions`, `actionsWhenSubject`,
`actionsWhenObject`, `relationships`, `relationshipsWhenSubject`,
`relationshipsWhenObject`.

Metodi:

```swift
action(types: String...) -> [Action]
action(types: [String]) -> [Action]
relationship(types: String...) -> [Relationship]
relationship(types: [String]) -> [Relationship]
relate(to entity: Entity)
is(relationship type: String) -> Relationship
will(action type: String) -> Action
did(action type: String) -> Action
```

`is(relationship:)` crea una relazione con l’entity come soggetto; l’oggetto si
può assegnare con `.of(entity)`, `.in(object:)` o con `relationship.object =`.
`will(action:)` e `did(action:)` creano un’azione con l’entity tra i soggetti.

### `Relationship`

Una `Relationship` descrive un collegamento orientato: parte da un `subject`,
ha un tipo e arriva a un `object`. Per esempio, una relazione `"writes"` può
collegare un utente a una nota.

Proprietà: `nodeClass`, `subject: Entity?`, `object: Entity?`.

```swift
of(_ entity: Entity) -> Relationship
in(object: Entity) -> Relationship
```

Sono equivalenti per impostare `object`; entrambi sono fluenti. Sono disponibili
anche su `[Relationship]`:

```swift
relationships.subject(types: String...) -> [Entity]
relationships.subject(types: [String]) -> [Entity]
relationships.object(types: String...) -> [Entity]
relationships.object(types: [String]) -> [Entity]
```

### `Action`

Un’`Action` rappresenta qualcosa che un gruppo di entità compie o a cui prende
parte. È utile quando un semplice collegamento non basta e servono uno o più
soggetti e oggetti associati.

Proprietà: `nodeClass`, `subjects: [Entity]`, `objects: [Entity]`.

```swift
add(subjects: Entity...) / add(subjects: [Entity]) -> Action
remove(subjects: Entity...) / remove(subjects: [Entity]) -> Action
add(objects: Entity...) / add(objects: [Entity]) -> Action
remove(objects: Entity...) / remove(objects: [Entity]) -> Action
what(objects: Entity...) / what(objects: [Entity]) -> Action
subject(types: String...) / subject(types: [String]) -> [Entity]
object(types: String...) / object(types: [String]) -> [Entity]
```

Le stesse quattro funzioni di filtro `subject/object` sono disponibili sulle
collezioni `[Action]`.

## 5. Predicati e ricerche

Le ricerche in GraphEvo si costruiscono componendo piccoli `Predicate`. Invece
di scrivere direttamente stringhe Core Data, si possono usare operatori e
funzioni leggibili come `.type("User")`, `.has(tags: "active")` o
`.member(of: "staff")`.

### `CompoundString`

```swift
public struct CompoundString: ExpressibleByStringLiteral
public init(stringLiteral: String)
public func &&(CompoundString, CompoundString) -> CompoundString
public func ||(CompoundString, CompoundString) -> CompoundString
public prefix func !(CompoundString) -> CompoundString
```

Serve per comporre stringhe di tipo, proprietà, tag o gruppi prima di costruire
un `Predicate`.

### `Predicate`

Operatori:

```swift
Predicate && Predicate -> Predicate
Predicate || Predicate -> Predicate
!Predicate -> Predicate
String == CVarArg -> Predicate
String != CVarArg -> Predicate
String > NSNumber -> Predicate
String >= NSNumber -> Predicate
String >= NSDate -> Predicate
String <= NSDate -> Predicate
String < NSNumber -> Predicate
String <= NSNumber -> Predicate
```

Costruttori statici, ciascuno con overload variadico, array e `CompoundString`
(e con `using: Compounder` per variadico/array):

```swift
Predicate.exists(_ properties: String... | [String] | CompoundString)
Predicate.exists(_ properties: String... | [String], using: Compounder)
Predicate.type(_ types: String... | [String] | CompoundString)
Predicate.type(_ types: String... | [String], using: Compounder)
Predicate.has(tags: String... | [String] | CompoundString)
Predicate.has(tags: String... | [String], using: Compounder)
Predicate.member(of groups: String... | [String] | CompoundString)
Predicate.member(of groups: String... | [String], using: Compounder)
```

I confronti stringa sono case/diacritic-insensitive. Il wildcard `"*"` è utile
per selezionare tutti i tipi: `.type("*")`.

### `Search<T: Node>`

```swift
public init(graph: Graph = Graph(...))
public func clear() -> Search<T>
public func `where`(_ predicate: Predicate) -> Search<T>
public func sync(completion: (([T]) -> Void)? = nil) -> [T]
public func async(completion: @escaping ([T]) -> Void)
public static func + (Search<T>, Search<T>) -> Search<T>
public static func += (inout Search<T>, Search<T>)
```

`where` aggiunge il predicato combinandolo con OR. `sync()` restituisce un array
vuoto se manca il predicato; l’uso di un tipo `T` non supportato genera un
`fatalError`. Il callback di `sync` viene portato sul main thread se necessario;
`async` esegue la ricerca in background. Gli operatori richiedono lo stesso
oggetto `Graph` e generano `fatalError` se i graph sono diversi.

## 6. Watcher e notifiche

Un `Watch` permette di reagire ai cambiamenti senza dover controllare
continuamente il database. Si può filtrare il tipo di oggetto osservato e
ricevere callback quando un oggetto viene creato, modificato o eliminato.
Lo stesso meccanismo distingue i cambiamenti locali da quelli arrivati da
CloudKit attraverso `GraphSource`.

```swift
public enum GraphSource: Int { case cloud; case local }
public protocol GraphNodeDelegate {}
public protocol Watchable { associatedtype Element: Node }

public struct Watcher {
    public var watch: Watch<Node>? { get }
    public init(object: AnyObject)
}
```

`GraphEntityDelegate`, `GraphRelationshipDelegate` e `GraphActionDelegate`
ereditano `GraphNodeDelegate` e forniscono callback Obj-C opzionali per:

- inserimento, aggiornamento e cancellazione del nodo;
- aggiunta, aggiornamento e rimozione di proprietà;
- aggiunta e rimozione di tag;
- ingresso e uscita da gruppi.

Le firme seguono lo schema:

```swift
graph(_: inserted/deleted entity: Entity, source: GraphSource)
graph(_: entity: Entity, added/updated/removed property: String, with value: Any, source: GraphSource)
graph(_: entity: Entity, added tag: String, source: GraphSource)
graph(_: entity: Entity, removed tag: String, source: GraphSource)
graph(_: entity: Entity, addedTo/removedFrom group: String, source: GraphSource)
```

Per relationship/action sostituire il parametro centrale con `relationship:` o
`action:` e il tipo corrispondente. I callback Cloud vengono emessi dopo il
merge del contesto e con `source == .cloud`; quelli locali con `.local`.

### `Watch<T: Node>`

```swift
public init(graph: Graph = Graph(...))
public var graph: Graph { get }
public weak var delegate: GraphNodeDelegate?
public var isRunning: Bool { get }
public func clear() -> Watch<T>
public func `where`(_ predicate: Predicate) -> Watch<T>
public func resume() -> Watch<T>
public func pause() -> Watch<T>
```

Il watcher è inizialmente fermo. `resume()` inizia l’osservazione; `pause()` la
sospende; `clear()` cancella il filtro. Come `Search`, `where` combina più
filtri con OR. Il delegate deve implementare uno dei tre protocolli specialistici
in base a `T` (`Entity`, `Relationship`, `Action`).

## 7. Eventi, CloudKit e compatibilità legacy

Gli eventi sono il modo consigliato per sapere cosa sta succedendo a GraphEvo:
se il database è pronto, se CloudKit non è disponibile, se è stato usato un
fallback locale oppure se una query o una migrazione ha prodotto un errore.
Assegnare un `GraphEventDelegate` permette all’applicazione di collegare questi
eventi al proprio sistema di log o alla propria interfaccia.

```swift
public enum GraphPersistenceMode { case local; case cloud; case localFallback }
public enum GraphState {
    case readiness(GraphReadiness)
    case cloudStatus(GraphCloudStatus)
    case persistenceMode(GraphPersistenceMode)
}
public enum GraphWarning: LocalizedError {
    case cloudStoreFallback(underlying: Error)
    case metadataPersistence(underlying: Error)
    case persistentHistoryTokenStore(underlying: Error)
    case persistentHistoryMissingTransactionAuthor
}
public enum GraphFailure: LocalizedError {
    case storeOpening(GraphStoreOpeningError)
    case migration(migrationID: String, phase: String, underlying: Error)
    case persistentHistory(underlying: Error)
    case query(underlying: Error)
}
public enum GraphEvent {
    case stateChanged(GraphState)
    case warning(GraphWarning)
    case error(GraphFailure)
}
public protocol GraphEventDelegate: AnyObject {
    func graph(_ graph: Graph, didReceive event: GraphEvent)
}
```

Gli eventi sono consegnati sul main thread. `GraphReadiness` descrive solo la
disponibilità tecnica dello store: un errore di migrazione applicativa è un
`GraphFailure.migration`, ma non implica necessariamente `.failed`.

Gli stati, i warning e gli aggiornamenti di avanzamento non vengono stampati
automaticamente su stdout; l’applicazione decide come registrarli. Gli errori
non recuperabili restano stampati come diagnostica minima.

API legacy:

```swift
public protocol GraphDelegate { /* callback legacy definiti in GraphLegacyContracts.swift */ }
public enum GraphCloudStatus { case available; case unavailable }
public protocol GraphCloudStatusDelegate: AnyObject {
    func graph(_ graph: Graph, iCloudStatusChanged status: GraphCloudStatus)
}
public enum GraphCloudStorageTransition: UInt { /* valori legacy */ }
```

## 8. Persistent History

Persistent History è il meccanismo usato per riconoscere i cambiamenti arrivati
da altri contesti o da CloudKit. GraphEvo conserva un token per ricordare fin
dove ha già elaborato la cronologia e ridurre il rischio di notifiche duplicate.

Le estensioni pubbliche di `Graph` espongono:

```swift
@objc func ph_prepareOnLaunchAfterContainerReady()
func processPersistentHistoryForRemoteChange()
func processPersistentHistoryBatch(completion: @escaping (Bool) -> Void)
```

Il primo metodo va chiamato dopo che il persistent container è pronto. Il
processamento legge le transazioni dopo l’ultimo token, filtra le transazioni
autoriali locali per evitare doppie callback, esegue il merge e avanza il token
solo dopo la consegna coerente degli oggetti osservati.

Sono presenti anche helper `ph_debug_*` pubblici per test/debug (`ph_debug_clearToken`,
`ph_debug_lastTokenExists`, `ph_debug_corruptTokenOnDisk`, `ph_debug_tokenStorageURL`,
`ph_debug_printAuthorAndContext`, `ph_debug_printTokenStatus`). Non usarli come
contratto applicativo di produzione. Gli helper diagnostici non stampanti modificano
o restituiscono lo stato senza produrre output implicito; stampano solo gli helper
con nome `ph_debug_print...`, quando invocati esplicitamente.

## 9. Migrazioni

Le migrazioni servono quando cambia il significato o la struttura dei dati
salvati. GraphEvo offre un ciclo di vita a fasi, un registro delle migrazioni,
backup e notifiche di avanzamento; la decisione su come trasformare i dati resta
però all’applicazione.

### Contratto `GraphMigration`

```swift
public protocol GraphMigration {
    var id: String { get }
    var version: Int { get }
    var completionSynchronization: GraphMigrationCompletionSynchronization { get }
    func backupRoot(for configuration: GraphStoreConfiguration?) -> URL?
    func handlePhase(_ phase: GraphMigrationManager.GraphLifecyclePhase,
                     configuration: GraphStoreConfiguration?, graph: Graph?,
                     context: GraphMigrationContext?,
                     completion: @escaping (GraphMigrationResult) -> Void)
    func needsRun(at phase: GraphMigrationManager.GraphLifecyclePhase,
                  configuration: GraphStoreConfiguration?, graph: Graph?,
                  context: inout GraphMigrationContext?) -> Bool
    func recognizesLegacyCompletion(at phase: GraphMigrationManager.GraphLifecyclePhase,
                                    configuration: GraphStoreConfiguration?, graph: Graph?) -> Bool
    func handleRemoteChanges(configuration: GraphStoreConfiguration?, graph: Graph?,
                             context: GraphMigrationContext?, inserted: [NSManagedObjectID],
                             updated: [NSManagedObjectID])
    func resetMigrationState(for configuration: GraphStoreConfiguration)
}
```

Default: `version == 1`, sincronizzazione `.local`, backup root calcolata dal
manager, nessuna gestione remota, nessun riconoscimento legacy e reset tramite
ledger.

```swift
public struct GraphMigrationContext {
    public init(_ values: [String: Any] = [:])
    public subscript<T>(key: String) -> T? { get }
    public mutating func set<T>(_ key: String, value: T)
    public var previousMigrationRecord: GraphMigrationRecord? { get }
}
public enum GraphMigrationResult { case done; case error(Error); case fallback; case skipped }
public enum GraphMigrationCompletionSynchronization: Equatable, Sendable {
    case local
    case localAndICloudKeyValueStore
}
```

### `GraphMigrationManager`

```swift
public enum GraphLifecyclePhase { case preInit; case postInit; case postMigration; case ready }
public static func defaultBackupRoot(for configuration: GraphStoreConfiguration) -> URL
public static func record(for migration: GraphMigration, configuration: GraphStoreConfiguration) -> GraphMigrationRecord?
public static func resetRecord(for migration: GraphMigration, configuration: GraphStoreConfiguration) throws
public static func registerCallback(for phase: GraphLifecyclePhase, _ callback: @escaping (GraphStoreConfiguration?, Graph?) -> Void)
public static func registerMigration(_ migration: GraphMigration)
public static func registerMigrations(_ migrations: [GraphMigration])
public static func handlePhase(_ phase: GraphLifecyclePhase, configuration: GraphStoreConfiguration?, graph: Graph?)
public static func handlePhase(_ phase: GraphLifecyclePhase, configuration: GraphStoreConfiguration?, graph: Graph?, completion: (() -> Void)?)
public static func handleRemoteEntityChanges(configuration: GraphStoreConfiguration?, graph: Graph?, inserted: [NSManagedObjectID], updated: [NSManagedObjectID], context: GraphMigrationContext? = nil)
```

Le migrazioni sono registrate una sola volta per `id`, in ordine di registrazione;
le fasi successive vengono accodate se una fase asincrona è ancora in corso.

### Ledger e logging

```swift
public enum GraphMigrationState: String, Codable, Sendable
public struct GraphMigrationRecord: Codable, Equatable, Sendable {
    public let migrationID: String
    public let version: Int
    public let state: GraphMigrationState
    public let startedAt: Date
    public let updatedAt: Date
    public let errorDescription: String?
}
public enum GraphMigrationLogLevel: String, Codable
public struct GraphMigrationLogEntry: Codable {
    public let date: Date
    public let migrationID: String
    public let phase: String
    public let level: GraphMigrationLogLevel
    public let event: String
    public let message: String
    public let metadata: [String: String]
}
public enum GraphMigrationLogger {
    public static let logDidAppendNotification: Notification.Name
    public static var fileLoggingEnabled: Bool
    public static func log(...)
    public static func logURL(for configuration: GraphStoreConfiguration) -> URL
}
```

Il logging su file è disabilitato di default; abilitarlo solo quando serve
diagnostica (`GraphMigrationLogger.fileLoggingEnabled = true`). Le entry di
livello `info` e `warning` non vengono stampate automaticamente su stdout:
restano disponibili tramite notifica e, se abilitato, nel file JSONL. Gli
errori vengono mantenuti su stdout come diagnostica minima.

### UI migrazioni

`Notification.Name.GraphMigrationProgressDidChange`, `ProgressKey`, `ProgressInfo`,
`FailureKey` e `FailureInfo` costituiscono il contratto per progress/failure UI.
API:

```swift
GraphMigrationManager.parseProgress(from: Notification) -> ProgressInfo?
GraphMigrationManager.parseFailure(from: Notification) -> FailureInfo?
GraphMigrationManager.postMigrationProgress(...)
GraphMigrationManager.observeMigrationProgress(using: (ProgressInfo) -> Void) -> NSObjectProtocol
GraphMigrationManager.observeMigrationFailure(using: (FailureInfo) -> Void) -> NSObjectProtocol
GraphMigrationManager.removeProgressObserver(_ observer: NSObjectProtocol)
```

### `MigrationBackupManager`

```swift
public enum ConflictPolicy { case overwrite; case skip; case duplicate }
public struct BackupDescriptor: Codable {
    public let migrationID: String
    public let label: String?
    public let originalPath: String
    public let createdAt: Date
    public let files: [String]
}
```

Funzioni pubbliche: `backupStore(at:migrationID:label:conflictPolicy:rootOverride:)`,
`backupFile(at:migrationID:label:conflictPolicy:rootOverride:)`, i due overload
equivalenti che ricevono `configuration` e `migration`,
`findBackupsForStore(migrationID:storeURL:rootOverride:)` e
`restoreToOriginalLocation(descriptor:from:overwriteExisting:)`.
Le funzioni sono `throws`; uno store copia `.sqlite` e, se presenti, `.sqlite-wal`
e `.sqlite-shm`. `duplicate` crea una cartella suffissata, `skip` riusa il backup
esistente e `overwrite` sostituisce la cartella.

## 10. Utility pubbliche

Questa sezione raccoglie strumenti di supporto: gestione di valori JSON,
codifica di oggetti eterogenei, archiviazione sicura, percorsi e operazioni sui
file. Non sono necessari per l’uso base del grafo, ma diventano utili quando si
devono salvare proprietà complesse o preparare migrazioni.

### `Model` e Core Data

```swift
public struct Model {
    public static func create() -> NSManagedObjectModel
}
```

`Model.create()` restituisce il modello Core Data programmatico usato da
GraphEvo. È utile quando si costruisce manualmente un `NSPersistentContainer`.

### JSON e Codable

`GraphJSON` è un wrapper navigabile su valori JSON:

```swift
GraphJSON.parse(_ data: Data, options: JSONSerialization.ReadingOptions = .allowFragments) -> GraphJSON?
GraphJSON.parse(_ string: String, options: JSONSerialization.ReadingOptions = .allowFragments) -> GraphJSON?
GraphJSON.serialize(_ object: Any, options: JSONSerialization.WritingOptions = []) -> Data?
GraphJSON.stringify(_ object: Any, options: JSONSerialization.WritingOptions = []) -> String?
GraphJSON(_ object: Any)
GraphJSON.isNil
asArray, asDictionary, asString, asInt, asDouble, asFloat, asBool, asNSData
subscript(index: Int), subscript(key: String), subscript(dynamicMember: String)
```

Supporta literal nil/string/int/bool/float/dictionary/array, `Equatable`,
`CustomStringConvertible` e `Sequence` (`GraphJSONIterator`).

`AnyCodable`:

```swift
public struct AnyCodable: Codable {
    public let value: Encodable
    public static var codables: [Codable.Type]
    public init?(_ value: Any)
    public func unwrap() -> Any
}
```

`AnyCodableObject`, `NSArrayOfAnyCodableObject` e
`DictionaryOfAnyCodableObject` sono wrapper `NSSecureCoding`/`Codable` per valori,
array e dizionari eterogenei; espongono rispettivamente `value`, `items` e le
API di `Collection` (`startIndex`, `endIndex`, `index(after:)`, subscript).

### Archiviazione sicura

```swift
public enum GraphArchiverError: Error
public enum GraphArchiver {
    public static func archive(_ object: Any) throws -> Data
    public static func unarchive(_ data: Data) throws -> Any
}
public final class GraphValueTransformer: NSSecureUnarchiveFromDataTransformer {
    public static func register()
}
```

`GraphValueTransformer.register()` è chiamato anche da `Graph`; può essere
chiamato esplicitamente durante la configurazione del modello Core Data.

### File

Enum: `VideoExtension`, `ImageExtension`, `TextExtension`, `SQLiteExtension`,
`FileType`. Conversioni: `VideoExtensionToString`, `ImageExtensionToString`,
`TextExtensionToString`, `SQLiteExtensionToString`.

`Schema.File` vale `"File://"`. `File` espone path standard (`documentDirectoryPath`,
`libraryDirectoryPath`, `applicationSupportDirectoryPath`, `cachesDirectoryPath`,
`rootPath`) e le utility:

```swift
fileExistsAtPath(_:) -> Bool
contentsEqualAtPath(_:andPath:) -> Bool
isWritableFileAtPath(_:) -> Bool
removeItemAtPath(_:completion:)
createDirectoryAtPath(_:withIntermediateDirectories:attributes:completion:)
removeDirectoryAtPath(_:completion:)
contentsOfDirectoryAtPath(_:shouldSkipHiddenFiles:completion:)
writeToPath(_:name:value:completion:)
readFromPath(_:completion:)
path(_:path:) -> URL?
pathForDirectory(_:) -> URL?
fileType(_:) -> FileType
```

### Metadata dello store

`GraphStoreMetadata` espone `isCompatible(...)`, `read(from:at:) throws`, due
overload di `write(...)` e `needsUpgrade(current:required:)`. Queste API leggono
e aggiornano le versioni `GraphStoreConfiguration.Versions`; non sostituiscono
una migrazione semantica dei dati.

## 11. Tool di merge e deduplicazione

Questi strumenti sono pensati per casi più avanzati, ad esempio l’importazione
di un database iniziale, la sincronizzazione di sorgenti diverse o la rimozione
di duplicati creati durante un merge. La mappa `uuidFieldMap` dice a GraphEvo
quale proprietà identifica logicamente un’entità oltre al suo ID interno.

```swift
public protocol DedupDiscriminator {
    func choosePreferred(_ lhs: Entity, _ rhs: Entity) -> Entity
}
public final class DedupTool {
    public init(graph: Graph, discriminator: DedupDiscriminator)
    public static func deduplicateBetween(primaryGraph: Graph, secondaryGraph: Graph,
                                          discriminator: DedupDiscriminator,
                                          uuidFieldMap: [String: String]) throws
    public func deduplicateAll(uuidFieldMap: [String: String]) throws
    public func deduplicateSingle(_ entity: Entity, uuidFieldMap: [String: String]) throws
}
```

`uuidFieldMap` associa il tipo Entity al nome della proprietà UUID logica.
Il discriminator decide il survivor; le relazioni vengono copiate/riagganciate
e i duplicati vengono eliminati.

`GraphDedupEngine.deduplicate(in:uuidFieldMap:discriminator:) throws` esegue la
deduplicazione interna al graph con riscrittura delle relazioni e salvataggio
Core Data.

`GraphMergeEngine` espone:

```swift
public struct GraphMergeReport {
    public let importedEntities, mappedEntities, unmappedEntities: Int
    public let recreatedRelationships, skippedRelationships: Int
    public let recreatedActions, skippedActions: Int
}

GraphMergeEngine.merge(from:secondaryGraph, into:primaryGraph,
                       uuidFieldMap: [String: String], sourceTag: String,
                       migrationID: String = "GraphMergeEngine") throws -> GraphMergeReport
```

Il merge copia prima le entity e poi ricrea relazioni/azioni. Entity importate
ricevono la proprietà `source`; quelle senza UUID vengono marcate come non mappate.

## 12. API non da usare come contratto applicativo

Il codice contiene classi Core Data `Managed*`, `Container`, `Context`, registri,
coordinator e helper `internal`/`fileprivate`. Non fanno parte dell’API pubblica
consumabile anche quando i nomi sono visibili nel sorgente. In particolare non
creare direttamente `ManagedEntity`, `ManagedRelationship` o `ManagedAction`:
usare sempre le facciate `Entity`, `Relationship`, `Action`.

## 13. Checklist d’integrazione

Per una prima integrazione conviene seguire questo percorso:

1. Configurare `GraphStoreConfiguration` e, se serve, `cloudKitContainerIdentifier`.
2. Creare `Graph` e gestire `whenReady`/`eventDelegate`.
3. Creare nodi usando `Entity(type, graph:)`; leggere/scrivere proprietà tramite
   subscript e salvare con `sync`.
4. Usare `Search` per query e `Watch` per callback locali/CloudKit.
5. Configurare Persistent History con `ph_prepareOnLaunchAfterContainerReady()`
   dopo l’apertura del container.
6. Registrare migrazioni prima di creare il graph e usare backup prima di operare
   sul file SQLite.
7. Gestire esplicitamente `GraphStoreOpeningError.incompatibleStore`: GraphEvo
   lascia lo store invariato e non effettua migrazioni automatiche.

## 14. Matrice rapida per agenti AI

| Intento | API da chiamare | Output/attenzione |
|---|---|---|
| Aprire database | `Graph(configuration:)` | `Graph`, readiness asincrona |
| Verificare apertura | `whenReady` | `Result<Graph, GraphStoreOpeningError>` |
| Creare oggetto | `Entity(type, graph:)` | `Entity` |
| Impostare proprietà | `entity["key"] = value` | valore `Any?` |
| Collegare oggetti | `entity.is(relationship:).of(other)` | `Relationship` |
| Cercare | `Search<Entity>.where(...).sync()` | `[Entity]` |
| Osservare | `Watch<Entity>.where(...).resume()` | delegate callback |
| Salvare | `graph.sync()` | completion `(Bool, Error?)` |
| Migrare | `GraphMigrationManager.registerMigration` | lifecycle phases |
| Fare backup | `MigrationBackupManager.backupStore` | descriptor + folder |
| Merge | `GraphMergeEngine.merge` | `GraphMergeReport` |
| Deduplicare | `GraphDedupEngine.deduplicate` | `throws` |
| Diagnosticare | `eventDelegate` | `GraphEvent` sul main thread |
