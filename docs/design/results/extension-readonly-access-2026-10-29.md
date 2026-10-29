# Containing-app/extension safeguard — 2026-10-29

The [first access contract](../graphevo-2-app-extension-access.md) implements a
v2 extension mirroring refusal and explicit local read-only opening. The
maintainer asked to follow Apple's supported boundaries and protect callers
rather than force two simultaneous native synchronizers. This does not settle
interactive widget writes or certify iOS App Group operation.

## Implemented boundary

The runtime detects an actual extension bundle using Bundle.main metadata/path
and refuses mirrored configuration before constructing a model, acquiring a
native gateway, creating a SQLite file or loading a container. The public error
is synchronizationUnavailableInExtension. Refusing all extension mirrored
openings is the selected conservative alpha policy, including isolated extension
stores; Apple's cited warning concerns simultaneous synchronizers of one store,
not a universal extension CloudKit ban. The internal injected-role tests
also assert pre-load hooks and model factories are not invoked, and that a
failed open leaves no gateway claim behind. V1 facade behavior is unchanged.

Public openReadOnly single/pair overloads select the ordinary container and
native read-only descriptions, without CloudKit options. They retain explicit
schema/role routing, reject missing files as missingStore, preserve incompatible
files, and reject admitted mutation bodies as readOnly. Same-process access-mode
ownership is not relaxed. Shared-resource tests read two distinct graph catalogs
and payloads with equal node UUIDs in both current/native schemas. Attachment
reads retain exact-byte integrity. No schema, automatic migration, lifetime
file lock, new merge policy or WidgetKit dependency was introduced.

## Checks and actual scope

- Full suite: **520 tests pass** — 322 legacy, 111 store, 64 runtime, 23 model.
- Selected Thread Sanitizer: **7 tests pass** across the new read-only/role suites.
- External Swift 6 Release ProcessConsumer: pass for both current/native schemas.
  One process retains the writable owner while a second opens read-only,
  observes initial 0, receives invalidation and value 1 after a commit, and sees
  1 on an independent fresh read. Reader mutations/createGraph are refused;
  parent verifies the single graph and committed value afterward.
- A separate ProcessConsumer child in a synthetic .appex bundle passes the
  actual Bundle.main role check through all public single/paired mirrored
  schema combinations, before any native store is created. No injected role,
  CloudKit credential or network success is part of this check.
- External Swift 6 Release ModelConsumer: pass.
- Generic iOS configured disposable public host: build succeeds.
- Manifest and diff checks pass. CI now runs ProcessConsumer as a macOS
  functional check, with deadlines but no performance threshold.

The consumer uses only public import GraphEvo and fresh external temporary local
fixtures. Successful fixtures are removed after completion; failed fixtures are
retained for diagnosis without replay. No application, device, cloud, account
or invitation data was used in this local concurrency check. Synthetic bundle
execution is not a real extension, signing, App Group sandbox or iOS suspension
certificate. A native CloudKit writer plus extension-local reader still needs
its own iOS experiment. PA02/O03 and account/revocation policy remain open.

## Prior incident disposition

#92 (including the acknowledged launcher) was reviewed at d2e095c with macOS/iOS
CI 40937899273 successful, and merged into the consolidation parent at 7a21bf6.
The maintainer authorized waiting for the historical black-screen/invitation
incidents to recur and proceeding; their causes remain open in the
[causal report](native-public-causal-triage-2026-10-29.md). This increment adds no
speculative invitation workaround or automatic retry.
