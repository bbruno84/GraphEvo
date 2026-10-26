# V02 — old invitation after voluntary leave

The supported sharing path **allowed the participant to rejoin through the
same invitation URL** after leaving. On the different-account iPhone XR,
public metadata for the prior private invitation was `pending`; one
`NSPersistentCloudKitContainer.acceptShareInvitations` call into the explicit
shared store recovered the exact A3 graph in the original local stores. The
owner iPad retained A/B5 for a full bounded observation window, with A's
participant now `accepted` and B owner-only. No new invitation was issued.

This extends the [post-leave fresh-replica check](v02-postleave-fresh-replica-2026-10-26.md):
there, a new XR replica stayed empty without acceptance while the old URL was
pending. The distinction is application-visible access after explicit
acceptance. Voluntary leave cannot be treated as permanent owner-enforced
revocation. The result comes from public Core Data sharing and CloudKit
metadata APIs, not Core Data internals.

The original run was `8A6E6A45-2D7D-44C9-B127-32A552C1F773`; previous
leave case `88DA5EBE-FBD8-4A71-8B0F-E6D959703807`; one-shot old-link case
`384DF70D-841E-4823-9175-3AAB06B75F46`. The XR began with `.left` state,
the original two stores and zero visible rows. Its report recorded metadata
status `pending` (raw 1), one acceptance call, exact prior record/share
identities and links, no B, no errors, and detached stores. The independent
owner process retained 57 snapshots over 120 seconds, all five members and
matching owner data, A owner+XR `accepted` (raw 2), B owner only, and no errors.

After evidence retention, a separate disposable cleanup case
`CFD3B045-9DF3-458F-B83E-B95F92277EAB` used the public owner participant
removal/persist path. The XR observed A3→A0 in its already-open original stores;
an owner reopen retained A/B5 with A owner-only. No owner graph data was purged.

The [Demo implementation and detailed evidence](https://github.com/bbruno84/GraphEvoDemo/pull/1)
are on the laboratory branch. The private local archive
`2026-10-26-V02-oldlink-384DF70D-841E-4823-9175-3AAB06B75F46` holds the
signed Development build record, final reports and protected invitation outside
Git. The Demo app Swift source SHA256 was
`ac82cbc750ad85be7007daecb44aa7475a054b8caa31a605fbd5e8f5a03f76d9`;
the full Simulator app suite passed. This result does not establish selective
local recovery, delivery deadlines or other sharing-lifecycle cases.
