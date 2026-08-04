# Utility e strumenti pubblici

Queste API completano il nucleo GraphEvo. Sono utili soprattutto quando le
proprietà contengono valori eterogenei, quando si gestiscono migrazioni o quando
si importano dati da un altro graph.

## `GraphJSON`

`GraphJSON` avvolge valori JSON e consente accesso sicuro a array, dizionari e
campi:

```swift
if let json = GraphJSON.parse(data) {
    let title = json["title"].asString
    let first = json["items"][0].asDictionary
}
```

API principali: `parse`, `serialize`, `stringify`, `asArray`, `asDictionary`,
`asString`, `asInt`, `asDouble`, `asFloat`, `asBool`, `asNSData` e i subscript
per indice, chiave e dynamic member.

## Valori eterogenei e archiviazione

- `AnyCodable` avvolge valori codificabili diversi;
- `AnyCodableObject` supporta `NSSecureCoding` e `Codable`;
- `NSArrayOfAnyCodableObject` rappresenta collezioni ordinate;
- `DictionaryOfAnyCodableObject` rappresenta dizionari eterogenei;
- `GraphArchiver.archive` e `unarchive` gestiscono dati archiviati in modo sicuro;
- `GraphValueTransformer.register()` registra il transformer usato dal modello.

Usare questi tipi quando un valore non è una semplice stringa, numero, data o
booleano. Verificare sempre che il valore sia tra le classi consentite dal
transformer.

## File e metadata

`File` offre operazioni asincrone per esistenza, lettura, scrittura, directory,
permessi e tipo di file. `GraphStoreMetadata` legge e scrive le versioni dello
store, ma non esegue la trasformazione semantica dei dati.

## Merge

`GraphMergeEngine.merge` importa entity da un graph secondario in uno primario.
Esegue prima la copia delle entity e poi ricrea relazioni e azioni. Restituisce
un `GraphMergeReport` con contatori per importazioni, mapping, relazioni e azioni.

Le entity importate ricevono una proprietà `source`; quelle prive dell’UUID
indicato in `uuidFieldMap` vengono marcate come non mappate.

## Deduplicazione

`DedupTool` e `GraphDedupEngine` raggruppano le entity usando una mappa tipo →
campo UUID e chiedono a `DedupDiscriminator` quale elemento conservare.

```swift
struct PreferNewest: DedupDiscriminator {
    func choosePreferred(_ lhs: Entity, _ rhs: Entity) -> Entity {
        lhs.createdDate >= rhs.createdDate ? lhs : rhs
    }
}

try GraphDedupEngine.deduplicate(
    in: graph,
    uuidFieldMap: ["User": "remoteID"],
    discriminator: PreferNewest()
)
```

La deduplicazione può eliminare oggetti e modificare relazioni: eseguire sempre
un backup e verificare il report prima di usarla su dati di produzione.
