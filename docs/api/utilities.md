# Public utilities and tools

These APIs complement the GraphEvo core. They are most useful when properties
contain heterogeneous values, when managing migrations, or when importing data
from another graph.

## `GraphJSON`

`GraphJSON` wraps JSON values and provides safe access to arrays, dictionaries,
and fields:

```swift
if let json = GraphJSON.parse(data) {
    let title = json["title"].asString
    let first = json["items"][0].asDictionary
}
```

Main APIs are `parse`, `serialize`, `stringify`, `asArray`, `asDictionary`,
`asString`, `asInt`, `asDouble`, `asFloat`, `asBool`, `asNSData`, and subscripts
for indexes, keys, and dynamic members.

## Heterogeneous values and archiving

- `AnyCodable` wraps different codable values;
- `AnyCodableObject` supports `NSSecureCoding` and `Codable`;
- `NSArrayOfAnyCodableObject` represents ordered collections;
- `DictionaryOfAnyCodableObject` represents heterogeneous dictionaries;
- `GraphArchiver.archive` and `unarchive` handle securely archived data;
- `GraphValueTransformer.register()` registers the transformer used by the model.

Use these types when a value is not a simple string, number, date, or Boolean.
Always verify that the value belongs to a class permitted by the transformer.

Platform images are stored as PNG `Data`. Legacy archives containing `UIImage`
on iOS or `NSImage` on macOS are accepted on their originating platform and
normalized to PNG data when first read, allowing existing stores to migrate
without an application-level rewrite.

## Files and metadata

`File` provides asynchronous operations for existence, reading, writing,
directories, permissions, and file type. `GraphStoreMetadata` reads and writes
store versions but does not perform semantic data transformations.

## Merge

`GraphMergeEngine.merge` imports entities from a secondary graph into a primary
graph. It first copies entities and then recreates relationships and actions. It
returns a `GraphMergeReport` with counts for imports, mappings, relationships,
and actions.

Imported entities receive a `source` property; entities without the UUID named
in `uuidFieldMap` are marked as unmapped.

## Deduplication

`DedupTool` and `GraphDedupEngine` group entities using a type-to-UUID-field map
and ask `DedupDiscriminator` which item to keep.

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

Deduplication may delete objects and change relationships: always create a
backup and inspect the report before using it on production data.
