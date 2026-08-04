# Watcher ed eventi di cambiamento

Un `Watch<T>` permette di ricevere notifiche quando cambiano nodi di un certo
tipo. È utile per aggiornare una UI o reagire a dati arrivati da un altro
contesto o da CloudKit.

## Creare un watcher

I watcher sono tipizzati e inizialmente fermi:

```swift
final class EntityEvents: GraphEntityDelegate {
    func graph(_ graph: Graph, inserted entity: Entity, source: GraphSource) {
        print("Inserita \(entity.type) da \(source)")
    }
}

let entityEvents = EntityEvents()
let watch = Watch<Entity>(graph: graph)
watch.delegate = entityEvents
watch.where(.type("Note"))
watch.resume()
```

Il delegate deve essere mantenuto in vita dall’applicazione. `Watch<Entity>` usa
`GraphEntityDelegate`; per gli altri tipi usare `GraphRelationshipDelegate` o
`GraphActionDelegate`.

## Ciclo di vita

- `resume()` inizia l’osservazione;
- `pause()` la sospende e rimuove le osservazioni;
- `clear()` rimuove il filtro;
- la deallocazione del watcher rimuove automaticamente le osservazioni.

È possibile riutilizzare lo stesso watcher chiamando `pause()`, modificando il
filtro e poi `resume()`.

## Tipi di callback

I tre delegate coprono lo stesso insieme di eventi:

- inserimento, aggiornamento e cancellazione del nodo;
- aggiunta, modifica e rimozione di proprietà;
- aggiunta e rimozione di tag;
- ingresso e uscita da gruppi.

Per una relationship o action il parametro principale cambia tipo, ma la forma
della callback resta la stessa.

## Origine del cambiamento

`GraphSource.local` indica una modifica osservata nel contesto locale.
`GraphSource.cloud` indica una modifica elaborata tramite il flusso di
Persistent History e proveniente da un altro contesto o da CloudKit.

Non assumere che ogni modifica Cloud generi una sola callback: il codice usa
transaction author e merge ordinato per ridurre i duplicati, ma l’applicazione
deve mantenere callback idempotenti.

## Filtri

```swift
watch.where(.type("User"))
watch.where(.has(tags: "active"))
```

Come per `Search`, chiamate successive a `where` vengono combinate con OR.
Costruire un singolo `Predicate` quando serve un AND esplicito.
