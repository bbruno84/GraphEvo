# Modello a grafo

GraphEvo organizza i dati come un insieme di oggetti collegati. Il vantaggio
principale è poter descrivere non solo gli oggetti, ma anche il modo in cui
sono collegati e le azioni a cui partecipano.

## Il `Graph`

`Graph` rappresenta uno store aperto. È il punto di ingresso per:

- creare `Entity`, `Relationship` e `Action`;
- eseguire ricerche;
- salvare o cancellare dati;
- ricevere eventi di apertura, persistenza e sincronizzazione.

```swift
var configuration = GraphStoreConfiguration()
configuration.name = "Main"
let graph = Graph(configuration: configuration)
```

Quando il risultato dell’apertura è importante, usare `whenReady` invece di
assumere che il graph sia già pronto.

## `Node`

`Node` è la base comune. Ogni nodo ha:

- `type`: tipo logico, ad esempio `"User"` o `"Note"`;
- `id`: identificatore persistente generato dalla libreria;
- `createdDate`: data di creazione;
- proprietà dinamiche accessibili con `node["key"]`;
- tag e gruppi.

```swift
let user = Entity("User", graph: graph)
user["name"] = "Ada"
user.add(tags: "active")
user.add(to: "authors")
```

Le proprietà sono di tipo `Any?`, quindi sono flessibili ma richiedono attenzione
quando si salvano valori complessi o non codificabili.

## `Entity`

Una `Entity` rappresenta un oggetto di dominio. Il tipo non è una classe Swift,
ma una stringa scelta dall’applicazione. Questo consente di modellare più tipi
di dati usando la stessa API.

```swift
let note = Entity("Note", graph: graph)
note["title"] = "GraphEvo"
note["isArchived"] = false
```

Un’entità può leggere le azioni e le relazioni di cui è subject o object:
`actions`, `actionsWhenSubject`, `actionsWhenObject`, `relationships`,
`relationshipsWhenSubject` e `relationshipsWhenObject`.

## `Relationship`

Una relazione è un collegamento orientato e tipizzato:

```text
subject --type--> object
```

Esempio:

```swift
user.is(relationship: "writes").of(note)
```

In questo caso `user` è il subject, `note` è l’object e `"writes"` è il tipo.
La stessa relazione può essere costruita assegnando direttamente `subject` e
`object`.

## `Action`

Un’azione descrive un evento o un’attività. Può avere più soggetti e più oggetti:

```swift
let review = user.will(action: "reviews")
review.add(objects: note)
```

`subjects` e `objects` restituiscono le entità associate. `will(action:)` e
`did(action:)` sono scorciatoie che inseriscono l’entità chiamante tra i
soggetti dell’azione.

## Tag e gruppi

I tag sono etichette, mentre i gruppi rappresentano appartenenze. Entrambi sono
gestiti come insiemi e non contengono duplicati.

```swift
user.add(tags: "active", "verified")
user.remove(tags: "verified")
user.toggle(tags: "featured")

if user.has(tags: ["active", "featured"], using: .and) {
    // entrambe le etichette sono presenti
}
```

Tutte le operazioni di modifica restituiscono il nodo e possono essere
concatenate. `delete()` rimuove il nodo dal contesto; chiamare `graph.sync()`
per salvare la cancellazione.

## Regole pratiche

- Creare sempre gli oggetti passando il `Graph` corretto.
- Usare `Relationship` quando il collegamento è un dato autonomo e tipizzato.
- Usare `Action` quando un evento coinvolge più partecipanti.
- Non usare direttamente le classi Core Data `Managed*`.
- Salvare esplicitamente con `sync()` dopo una sequenza di modifiche.
