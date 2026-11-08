# Initial publication and replica recovery cost

This lab investigates the synthetic 36 × 720,000-byte string fixture in
`GraphCloudActivationTests.publishesAndRecoversSeedAboveTheFormerAggregatePayloadLimit`.
It uses the native SQLite/codec/journal path with an in-process CloudKit service,
not Apple's network. Keep functional assertions and native read/write grants.
Do not interpret elapsed time as upload bandwidth.

## Native Foundation control

The standalone probe has no GraphEvo, Core Data, network or payload bytes. It
compares a presenter on the coordinated directory with a presenter on its child
registration directory. Both must deny parent deletion while registered and
admit it after unregistering. It does not actually delete inside the accessor.

```sh
GRAPHEVO_BUILD_LABS=1 swiftc -D GRAPHEVO_BUILD_LABS -swift-version 6 \
  -parse-as-library Experiments/ActivationPublicationCost/NativePresenterProbe.swift \
  -o /tmp/graphevo-native-presenter-cost
/tmp/graphevo-native-presenter-cost
```

The current runtime presents the existing `.owners-v1` directory and continues
to coordinate operations on the same canonical root. The ledger format and
coordination address do not change. The native control establishes bounded
behavior on the tested OS, not an OS-wide fixed latency guarantee.

## Phase and native callback timings

Use a clean, disposable checkout. The diagnostic patch modifies only the test
fixture, preserves all assertions and records payload-free stage/callback totals.
Its five-minute diagnostic guard permits the historical slow implementation to
finish; the shipping functional test retains two minutes. Revert the patch
before publishing or running ordinary acceptance checks.

```sh
git apply --check --unidiff-zero Experiments/ActivationPublicationCost/timing.patch
git apply --unidiff-zero Experiments/ActivationPublicationCost/timing.patch
swift test --filter publishesAndRecoversSeedAboveTheFormerAggregatePayloadLimit
# After collecting the diagnostic run:
git apply --reverse --unidiff-zero Experiments/ActivationPublicationCost/timing.patch
```

For the tested Swift 6.4.2 toolchain, ordinary `swift test -c release` also builds
legacy tests that depend on DEBUG-only helpers. Build the v2 test product directly
with testing visibility; this retains optimization and does not define DEBUG:

```sh
swift build -c release --product GraphEvoStoreTests -Xswiftc -enable-testing
probe_developer_dir="$(xcode-select -p)"
probe_swift_bin="$(dirname "$(xcrun --find swift)")"
probe_products="$(swift build -c release --show-bin-path)"
probe_bundle="$probe_products/GraphEvoStoreTests.xctest/Contents/MacOS/GraphEvoStoreTests"
DYLD_FRAMEWORK_PATH="$probe_developer_dir/Platforms/MacOSX.platform/Developer/Library/Frameworks" \
DYLD_LIBRARY_PATH="$probe_developer_dir/Platforms/MacOSX.platform/Developer/usr/lib:$probe_swift_bin/../lib/swift/macosx" \
"$probe_swift_bin/../libexec/swift/pm/swiftpm-testing-helper" \
  --test-bundle-path "$probe_bundle" \
  --filter publishesAndRecoversSeedAboveTheFormerAggregatePayloadLimit \
  "$probe_bundle" --testing-library swift-testing
```

Product/runner layouts vary by toolchain: inspect its build output rather than
changing library code to satisfy legacy Release test seams. Build completion is
not a successful test; require the test's passing summary.

Compare isolated runs without competing builds. Phase wall times include native
callbacks, so do not add them to callback totals. Keep samples/logs/stores external
and private. This lab has no ordinary CI target or performance pass threshold.
