# Representative v1 migration with private CloudKit Development

The MyHomeBills sample completed v1-to-v2 native conversion, private CloudKit
publication and recovery into a newly created SQLite store on a physical
10th-generation iPad. The signed external probe used GraphEvo revision
`872ef5b3` from [PR #185](https://github.com/bbruno84/GraphEvo/pull/185).
The test used a copy of the v1 archive and a fresh private Development zone.

- Native conversion produced 1,577 mapped primitives.
- CloudKit published after 110 activation advances. Publication included
  verification of the complete server inventory. The probe began independent
  recovery 568 seconds after starting.
- A fresh store on the same iPad recovered the graph. Canonical comparison
  matched all node IDs, topology, values and inline binary content against the
  converted source. The replica had zero outgoing changes.
- The run finished in 716 seconds. The device stores, source archive, zone
  identity and raw evidence are retained outside the repository.

This covers one representative source, one account and same-device recovery
after completed publication. A second physical device, forced interruption,
older source formats and production cutover require separate acceptance.
