# Search e Predicate

`Search<T>` esegue ricerche tipizzate sugli oggetti del graph. `Predicate`
fornisce un linguaggio compatto per descrivere i filtri senza costruire a mano
le stringhe di `NSPredicate`.

## Ricerca di base

```swift
let users = Search<Entity>(graph: graph)
    .where(.type("User"))
    .sync()
```

Il tipo generico deve essere uno dei nodi supportati (`Entity`, `Relationship` o
`Action`). Senza un predicato, la ricerca restituisce un array vuoto.

## Filtri disponibili

```swift
.type("User")
.exists("email")
.has(tags: "active")
.member(of: "staff")
```

Le funzioni accettano anche array e combinazioni di stringhe. I confronti sulle
proprietà usano la sintassi naturale:

```swift
"name" == "Ada"
"age" >= 18
"createdAt" <= someDate
```

Le stringhe sono confrontate ignorando maiuscole/minuscole e diacritici.

## Comporre i predicati

```swift
let filter = (.type("User") && .has(tags: "active")) || .type("Admin")
let visible = Search<Entity>(graph: graph).where(filter).sync()
```

Sono disponibili `&&`, `||` e il prefisso `!`.

```swift
let notArchived = !("isArchived" == true)
```

## Attenzione ai `where` successivi

L’implementazione attuale di `Search.where` combina i predicati aggiunti in
chiamate successive con OR:

```swift
let result = Search<Entity>(graph: graph)
    .where(.type("User"))
    .where(.type("Admin"))
    .sync()
```

La ricerca precedente significa quindi “User oppure Admin”. Per esprimere
condizioni AND, costruire un singolo predicato con `&&`.

## Risultati sincroni e asincroni

```swift
let result = Search<Entity>(graph: graph)
    .where(.type("Note"))
    .sync()

Search<Entity>(graph: graph)
    .where(.type("Note"))
    .async { notes in
        updateUI(with: notes)
    }
```

`sync()` restituisce subito l’array. La sua completion opzionale viene eseguita
sul main thread. `async()` avvia la ricerca in background.

## Paginazione

`Graph` espone `batchSize` e `batchOffset`, applicati alle ricerche successive:

```swift
graph.batchSize = 20
graph.batchOffset = 40
let page = Search<Entity>(graph: graph).where(.type("Note")).sync()
```

Impostare `batchSize = 0` per rimuovere il limite.

## Combinare ricerche

```swift
let users = Search<Entity>(graph: graph).where(.type("User"))
let admins = Search<Entity>(graph: graph).where(.type("Admin"))
let both = (users + admins).sync()
```

Le due ricerche devono appartenere allo stesso `Graph`.
