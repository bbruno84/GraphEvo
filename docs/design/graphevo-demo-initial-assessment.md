# GraphEvoDemo — initial laboratory assessment

Assessment date: 2026-10-23. Scope: V00 of the
[verification roadmap](graphevo-2-verification-roadmap.md). This is an inventory
and build assessment, not a result for experiments V01–V08.

## Source state

The companion repository already exists locally at `../GraphEvoDemo` and is
published at <https://github.com/bbruno84/GraphEvoDemo>.

The inspected checkout is on `feature/expand-graph-evo-coverage`, at `b438732`
(`docs: add demo agent guidelines`). After fetching, its HEAD matches the
repository's `origin/develop`. The working tree contains substantial existing
work: 14 modified tracked files, plus untracked view models, a test directory,
feature documentation, and Xcode user data. The assessment includes that local
work; it does not describe only the committed revision or a clean clone.
No source files, branch selection, dependency pins, or signing settings in that
checkout were changed during the assessment.

For build verification, the application, tests, project, and documentation were
copied to a temporary directory, excluding Xcode user data. Builds use separate
DerivedData and preserve the dependency revision through
`-onlyUsePackageVersionsFromResolvedFile`.

## Configuration and dependencies

- UIKit iOS application with the shared `GraphEvoDemo` scheme and a
  `GraphEvoDemoTests` target included in its test action.
- Deployment target: iOS 17.6. Project language mode: Swift 5 (`SWIFT_VERSION =
  5.0`), not a demonstrated Swift 6 language-mode consumer.
- GraphEvo package requirement: remote `develop` branch. The inspected lockfile
  pins `ae111160254b9a6c441f8418134bf868e4d1deeb`, dated 2026-08-10.
  GraphEvo `develop` at `4dc0a7f` is 68 commits ahead of that revision. A branch
  requirement alone does not establish current dependency alignment.
- Bundle, CloudKit container, and development team use documented neutral
  placeholders. Real cloud checks need a dedicated account-owned Development
  configuration; successful unsigned compilation does not validate it.
- The shared scheme's diagnostic environment-variable keys contain trailing
  newline characters. Their intended logging behavior needs correction or
  verification before relying on diagnostics as experimental evidence.

## Existing material worth retaining

| Component | Observed implementation | Laboratory value and limits |
|---|---|---|
| GraphProvider | Opens the shared Main graph, handles readiness, cloud status/events/import completion, and prepares history | Existing gateway for v1 integration; no isolated direct-framework experiment stack |
| Notes and detail screens | Create/read/delete notes, toggle favorite tags, and connect attachments | Useful interactive graph fixture; currently dynamic properties and synchronous queries/saves |
| NotesViewModel | Owns queries and a resumed Watch delegate | Baseline for current observation behavior; not evidence for future observable-query semantics |
| DeveloperViewModel | Status, history token/author diagnostics, action/group and predicate probes | Useful controls; token clearing and data clearing must stay explicit |
| Binary probes | A 1.5 MB Data property and random stress data with attachments | Starting fixture, not a dedicated attachment API, checksum round trip, or measured performance test |
| Feature guide | Explains graph lifecycle, model operations, queries, watchers, and cloud setup | Useful onboarding; some wording still attributes watcher ownership to the controller rather than its view model |

The current stress probe clears graph data first and uses random counts and
sizes. It must not become a verification fixture without disposable scope,
deterministic inputs, and repeatable assertions. Some diagnostics also describe
successful local saves as being sent for synchronization; that wording is not
proof of export or remote receipt.

## Tests and build evidence

The inspected test source contains four XCTest methods covering domain
operations, compound predicates, callback-based asynchronous search, and local
watcher insertion after resume. They use in-memory Graph instances. They do not
exercise the view models directly, durable SQLite reopening, real cloud import,
sharing, or the v2 requirements.

Environment: Xcode 27.0 (`27A266a`), Apple Swift 6.4 toolchain. The configured
Swift 5 language mode remains unchanged.

- App simulator build: passed using XcodeBuildMCP for iPhone 18 Pro / iOS 27.0,
  with `CODE_SIGNING_ALLOWED=NO` and the pinned package revision. The log confirms
  `GraphEvo @ develop (ae11116)` and `BUILD SUCCEEDED`.
- Test-target compilation: passed with `xcodebuild build-for-testing`, a generic
  iOS Simulator destination, the same dependency pin, separate DerivedData, and
  signing disabled. The log ends with `TEST BUILD SUCCEEDED`. This compiles the
  test bundle without running its assertions.
- Test execution, app launch, UI interaction, real-device signing, and cloud
  behavior: not performed. All listed simulators were shut down at inspection.
- Existing demo working-tree whitespace check: passed.

The app build log contains an App Intents metadata-extraction warning because
there is no AppIntents dependency; no Swift compiler errors were observed in
that successful build. This assessment does not imply all test assertions pass.

## Recovery work to plan before V01

1. Review and preserve the existing uncommitted demo work, including its tests
   and documentation, before creating an experiment branch from current develop.
2. Align the GraphEvo dependency deliberately with the selected baseline and
   rebuild/retest. Keep results against the original pin distinguishable.
3. Run the baseline tests and launch the UI on an available simulator, then
   validate the dedicated Development identity/signing on real devices.
4. Add a separate framework experiment entry point without mixing its lifecycle
   with GraphProvider. Decide how local configuration is supplied without
   committing account-specific identifiers.
5. Add deterministic fixtures, per-experiment stores, readable outcome reports,
   checksums where relevant, and explicit cleanup. Validate diagnostic switches.

The demo is a useful existing v1 integration harness, with a successful app
build. It is not yet a validated framework laboratory. No recovery code or
framework experiment was implemented during this assessment.
