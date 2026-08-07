# Persistent History

Persistent History consente di capire quali modifiche sono state salvate in
Core Data dopo l’ultima elaborazione. GraphEvo lo usa per consegnare ai watcher
i cambiamenti arrivati da altri contesti e da CloudKit.

## Avvio

Chiamare il metodo pubblico dopo che il persistent container è pronto:

```swift
graph.ph_prepareOnLaunchAfterContainerReady()
```

GraphEvo carica il token salvato, oppure prepara una sessione iniziale senza
perdere la cronologia necessaria.

## Elaborazione

`processPersistentHistoryForRemoteChange()` accoda l’elaborazione. Per gestire
una singola batch con completion usare:

```swift
graph.processPersistentHistoryBatch { processed in
    print("Batch elaborata: \(processed)")
}
```

Il flusso generale è:

1. caricare l’ultimo token;
2. leggere le transazioni successive;
3. ignorare le transazioni autoriali locali quando opportuno;
4. raccogliere gli object ID inseriti, aggiornati e cancellati;
5. fondere le modifiche nel contesto osservato;
6. notificare i watcher;
7. salvare il nuovo token solo dopo la consegna.

## Token

Il token viene salvato su disco in un percorso associato allo store e mantenuto
anche in un backup locale. Con `appGroupIdentifier` il percorso del token può
risiedere nell’App Group.

L’identità del token è derivata dall’URL canonico e, quando disponibile, dal
`NSStoreUUID` del persistent store. Se GraphEvo rileva una ricostruzione con una
nuova identità di store, non riusa il token precedente.

Il token identifica il punto della cronologia già elaborato, non un oggetto del
dominio. Non usarlo per ricostruire direttamente l’identità delle entità.

## Callback duplicate

GraphEvo assegna un transaction author ai contesti locali e filtra le transazioni
del dispositivo originario. Nonostante questo, l’applicazione deve progettare
callback idempotenti: lo stesso cambiamento può essere osservato in più momenti
quando Core Data, CloudKit e UI lavorano su contesti diversi.

## Eventi ed errori

I token corrotti vengono invalidati insieme al file e al backup UserDefaults e
GraphEvo porta il punto di recovery alla history head corrente. Lo stesso
recovery viene applicato a:

- `NSCocoaErrorDomain` `134301`: token Persistent History scaduto;
- `NSCocoaErrorDomain` `134501`: token riferito a uno store non più presente.

In entrambi i casi il coordinatore non ripete il token invalido alle successive
remote-change notification e GraphEvo emette una sola diagnosi
`GraphWarning.persistentHistoryRecovery` per il recovery eseguito. Questo
bootstrap può saltare transazioni non più rappresentabili dal token; non
genera callback watcher artificiali.

Gli altri errori del token producono `GraphWarning.persistentHistoryTokenStore`; una
transazione senza autore produce
`GraphWarning.persistentHistoryMissingTransactionAuthor`;
gli errori di elaborazione producono `GraphFailure.persistentHistory`.
Usare `GraphEventDelegate` per registrarli.

Gli helper `ph_debug_*` sono destinati a test e diagnostica, non al normale
flusso applicativo. Le varianti che non hanno `print` nel nome non producono
output implicito; le varianti `ph_debug_print...` stampano solo quando chiamate
esplicitamente.
