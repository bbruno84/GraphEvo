# Apple background expiration and App Group handoff

The [R device continuation](apple-owner-r-device-validation-2026-11-05.md)
used a laboratory timer to end its explicit UIKit background task. These
additional physical iPadOS 27.0 tests use fresh synthetic S04 stores and the
same R coordination path in a separate laboratory namespace.

With a failed detach, the widget's deletion probe was refused 0.81 seconds
after background entry. UIKit invoked the expiration handler at 26.46 seconds.
The host ended the task about 5 ms later, with the native store still attached.
The console recorded signal 9 and consecutive process inventories bracketed the
owner's disappearance. The first replacement grant lacked a verified order
relative to exit. A deletion probe explicitly initiated after the inventory
reported the owner absent obtained a dry-run grant. A fresh process verified
the two original records, including exact identities and payload digests.
The observed expiration time is specific to this run.

When a widget accessor delayed closing, the host submitted a close request
after entering background. With the UIKit task active, its request waited
about 12.48 seconds, then obtained access after the widget accessor returned.
The host detached and ended the task. This control covers a close waiting in
background with execution time available.

A separate queue control ended the host task 28 ms after close submission
while the widget was still in its accessor. The host console recorded signal 9.
The close trace contains submission only. There was no recorded grant, detach
or cancellation callback, including `NSUserCancelledError`. A deletion probe
initiated after the host was confirmed absent obtained a dry-run grant. The
reopened store contained both original records with exact identities and
payload digests. The cause of signal 9 remains undiagnosed.

In the successful handoff control, an already admitted host write committed
once, a new read was refused during closure and the host detached 2.47 seconds
after background entry. It ended the UIKit task 2.99 ms after native detach.
The widget's native attachment preceded host detach by 18.83 ms. Its write
grant followed host detach and task release, and its store detached before the
widget action returned. A fresh process verified both writes and the two
original records. This run establishes the observed write ordering with
overlapping native attachments.

The probes leave files intact. The conditions for production adoption remain
open, including actual destructive maintenance and the physical iOS 18 gate.

The private verifier checks both evidence manifests. The primary manifest
SHA-256 is `9b5b05ecd0e7a11b35fde56c37737215253cd47ddd8f657e7dfa3b713903369e`.
The queue release manifest SHA-256 is
`24130b3c32cb5fe519d667b4295d84f860ecd6eae88951cdafde9f64cc06a770`.
