# PackageConsumer integration fixture

This fixture checks GraphEvo from the perspective of an external Swift Package Manager consumer. It imports the public `GraphEvo` product, opens a temporary local store, and exercises a minimal Entity create, read, update, and delete cycle.

It intentionally does not verify CloudKit, entitlements, UIKit, SwiftUI, persistent history, migrations, or the full GraphEvoDemo application. Those concerns are covered by other tests or require an application environment.

The fixture uses a local package dependency to the repository root so it can run in the same checkout without a circular dependency. This validates package/product resolution and public API consumption, but it does not replace a test against a published remote version of GraphEvo. A remote-package check would require a separate consumer repository or an already published tag.

Run it from the repository root with:

```bash
swift run --package-path IntegrationTests/PackageConsumer
```
