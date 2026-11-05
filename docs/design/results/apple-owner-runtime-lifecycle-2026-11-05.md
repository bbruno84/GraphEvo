# Apple presenter with the native graph lifecycle

The private P experiment attaches an `NSFilePresenter` to the actual S04
`StoreResources` owned through `GraphContext`. It selects one canonical SQLite
fixture in a dedicated directory. The presenter registers before native load
and unregisters after Core Data reports zero attached stores. The runtime's
existing ownership and writer locks remain active in this experiment.

Two public graph handles share one native owner. An independent process issues
dry-run Foundation deletion and replacement requests against the fixture
directory with both handles live, after the first close, after final close and
after reopen. The presenter refuses all six requests with a live owner. Both
requests after final close are granted. The old handle reports closed and the
reopened graph has a distinct presenter and exact record identity and contents.
The comparison run without a presenter grants all eight Foundation requests,
including the six issued while the existing presence lock is held. The probe
performs no filesystem mutation. The initial fixture selector missed the store
and the probe was granted. That run is retained. The corrected selector uses
the runtime's canonical resource key and path.

A second private test composes the same presenter patch with the public graph
and connection lifetimes, actual GraphEvo transport state and public query
observation. An injected driver holds one send before delivering its receipt.
Explicit graph pause waits for that admitted operation and rejects new sends.
A later local edit and an unapplied remote record remain durable. The test then
closes the connection, closes the final graph handle and observes the end of
the old stream before reopening with a fresh context.

On reopening, the query sees the latest local edit. The inbox record and the
pending local edit apply and send respectively. The old driver callback is
exercised while its retired session is still retained, with late state,
receipt, incoming-record and account events. The new durable session and
account state retain their expected values. The old query stream stays ended
and the new stream observes the applied record.

The test passed with the ordinary runtime and with the presenter attached.
The 11-test pause suite also passed with the same presenter patch. Monotonic
traces put transport close before native detach, detach before presenter
removal, and old observation completion before the new attachment. This is a
macOS composition test with injected network events and explicit shutdown.
It leaves the iOS background transition, replacement of the existing presence
lock, and routing of native writes through Apple coordination to subsequent work.

The next experiment needs an explicit admission boundary for the participating
context. A background request closes admission before awaiting the drain. The
owner drains admitted synchronization work, stops the participating transport,
then closes the store leases. A foreground request during closure waits for
that generation to finish. A successful reopen publishes fresh handles and
observations. A failed native detach retains the old owner and excludes a
replacement. The existing foreground activity signal controls scheduling and
does not by itself implement this ownership transition. A participating
connection shared by multiple graphs requires a context-wide drain or an
explicitly scoped pause before changing connection ownership.

Independent verification covered the 48-entry probe manifest and the composed
lifecycle logs, including the exact ordering and fresh owner identities.
Private P report SHA-256
`7d443051439e4ffd946f5cf01fce290266ac9deb200e11f708d9f88bcbbaccb9`.
Private P manifest SHA-256
`ba34be6b23a44bb98ae774eb0696d0a79aa5b51280e03bea0a9062cbbd955b17`.
Private composed lifecycle manifest SHA-256
`8393503d726f95d2b201b44996b9ac078a1b949ffcb19b805c608bfe72bfa349`.
