# PackageConsumer integration fixture

This fixture checks GraphEvo from the perspective of an external Swift Package Manager consumer. It imports the public `GraphEvo` product, opens a temporary local store, and exercises a minimal Entity create, read, update, and delete cycle.

It intentionally does not verify CloudKit, entitlements, UIKit, SwiftUI, persistent history, migrations, or the full GraphEvoDemo application. Those concerns are covered by other tests or require an application environment.

The fixture uses a local package dependency to the repository root so it can run in the same checkout without a circular dependency. This validates package/product resolution and public API consumption, but it does not replace a test against a published remote version of GraphEvo. A remote-package check would require a separate consumer repository or an already published tag.

Run it from the repository root with:

```bash
swift run --package-path IntegrationTests/PackageConsumer PackageConsumer
```

The second executable is a non-UI Swift 6 model consumer. It imports only the
public GraphEvo product, maps an ordinary Sendable application model, transfers
its values across tasks and the main actor, and performs typed SQLite CRUD,
including a partial edit retaining an unknown encoded field, awaited close/reopen
with stable identities, and deletion through the public v2 gateway.

```bash
swift run --package-path IntegrationTests/PackageConsumer ModelConsumer
```

The fixture manifest requires Swift tools 6.0. The legacy executable retains
Swift 5 language mode; ModelConsumer uses Swift 6 language mode.


ModelConsumer also exercises the explicit fresh local native-identity schema
through the public product: SQLite creation, a typed model, storage integrity,
query/Combine and reopen. This does not enable native-column mirrored selection
or assert cross-device synchronization.

Both explicit mirrored schema overloads are compiled and exercised against
non-file URLs for current/native selection. These fail configuration validation
before native/cloud loading and require no iCloud credentials. Successful native
private/private-shared opening belongs to the separate public device consumer;
invalid-URL refusal must not be presented as CloudKit synchronization evidence.


### Independent-process local reader

`swift run --package-path IntegrationTests/PackageConsumer ProcessConsumer`
(or `-c release`) runs a Swift 6 public consumer with two actual macOS processes
for each of the current/native schemas. It creates only fresh external temporary
fixtures, retains the writer while the child reads, verifies observation and a
fresh read after the writer commits, rejects child mutations before body execution,
and checks that no graph was created by the reader. Successful fixtures are
removed after process completion; failed fixtures remain external for diagnosis,
with no automatic replay. There are functional deadlines, no latency pass thresholds.
A child packaged in a synthetic .appex bundle also exercises real Bundle.main
classification and refuses both public mirrored overloads/schemas before native
loading. CI runs this on macOS. It does not certify an iOS extension, App Group sandbox,
CloudKit mirroring, suspended widget delivery or concurrent widget writes.
