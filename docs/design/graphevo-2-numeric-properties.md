# Expanded numeric property mapping

Status: focused alpha increment on `codex/v2-numeric-property-values`, directly
from integrated #131. This expands model-facing `GraphPropertyValue` conversions;
it does not adopt the TP01 native-property schema or change the query planner.

## Accepted Swift types

| Swift types | Existing logical GraphValue case |
|---|---|
| Int8, Int16, Int32, Int, Int64 | integer(Int64) |
| UInt8, UInt16, UInt32, UInt, UInt64 | unsignedInteger(UInt64) |
| Float, Double | floatingPoint(Double) |

Int/Int64/UInt64/Double already conformed. This increment adds Int8/Int16/Int32,
UInt/UInt8/UInt16/UInt32 and Float. Signedness remains explicit; width belongs to
the application model rather than a new logical payload discriminator. Existing
Optional, Array and string-keyed Dictionary conformances compose automatically.
No new GraphValue cases, encoded versions or per-model native entities appear.

Encoding the added integer types widens exactly to the appropriate 64-bit case.
Decoding requires that exact case and checks `init(exactly:)`: no overflow,
truncation, sign conversion or Bool/string/floating coercion is accepted.
`GraphRecord.value(for:as:)` retains the property key and underlying error when a
narrow value cannot be decoded. Typed patch validates the target model before
editing, so narrowing failure does not publish or save a partial update.

Every finite Float widens exactly to Double. Decoding a Double as Float succeeds
only when it is finite and exactly representable: it rejects rounding, overflow
and underflow. Use the actual Float's `graphValue` in mapping and query literals:

```swift
let fraction: Float = 0.1
let stored = fraction.graphValue
let restored = try Float(graphValue: stored)
```

A separately constructed Double(0.1) is a different binary value and is not an
exact Float; its narrowing is refused. Signed zero and Float subnormal/extreme
finite values round-trip through the existing codec in regression coverage.
Non-finite floating values remain non-serializable by the current JSON codec;
this increment does not introduce a NaN/Infinity wire representation.

## Persistence and transport boundaries

The unchanged scalar cases and GraphValueCodec represent these values both
locally and in the serialized cloud payload. No native S03, field, logical
identity, cloud node/asset, session or backup format changes; no migration is
required for these conformances. A public property numeric type does not change
GraphModel identity binding or make arbitrary numeric IDs graph identities.

Native columns, UUID/URI adoption, scalar dispatch, Decimal precision, Unicode/
NUL/relative-URL fidelity and hybrid Core Data predicate planning remain the next
schema/planner increment. Core Data's physical Integer16/32/64 or Float/Double
attribute choices need not become separate GraphValue cases. The model mapping
continues to precede internal persistence routing, and consumer binary Data is
not automatically reclassified as an attachment.

## Verification

New tests exercise every added integer width at zero/bounds, negative signed
values, just-outside-range inputs and category mismatches. Eight Float cases
check exact bit patterns after widening and codec round-trip; separate checks
cover rounding/underflow/overflow/non-finite rejection, nullable collections and
keyed decoding errors. Existing codec golden fixtures remain unchanged.

The independent public ModelConsumer stores all eight newly accepted types,
queries canonical signed/floating values, closes/reopens a native SQLite fixture,
patches a value and verifies an overflowing typed patch leaves saved data intact.
This is local public-API integration, not physical CloudKit/schema acceptance.
Review and the final CI checkpoint precede integration; experiments stay local.

Local checks pass 897 macOS functions (331 legacy, 462 store, 76 runtime, 28 model),
28 iOS model functions/35 invocations, both independent consumers and manifest/
diff validation. Agent review checks signedness, exact range conversion, finite
Float fidelity and unchanged codec/schema boundaries; no remaining blockers are
identified. The final full CI checkpoint is requested after that review. This
narrow API addition does not close native-property/query or physical cloud gates.
