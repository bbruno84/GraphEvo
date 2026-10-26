# V02 — incremental cross-account graph members

The owner iPad added A-003 and edited A-001 after A had been shared privately
with the different-account XR. The change used a Core Data relationship and
save, with **no explicit share call** for the child. The XR's already-open
container remained at A3 for its 90-second window, but a later read-only
reopen recovered A4. All A values, links, normalized record IDs and share IDs
matched the owner; B stayed owner-only. A subsequent owner deletion of A-003
was observed live as A4→A3 in the same open XR container, with the corrected
inverse link and owner A/B preserved. This is positive evidence for eventual
owner-driven membership and deletion, without a guaranteed import deadline.

The reciprocal participant-insertion test did **not** pass. The XR process
crashed after reserving the write stage and before retaining `mutationSaved`;
the private device crash log records `NSInvalidArgumentException` during Core
Data CloudKit serialization. The owner stayed at A3+B2 for the complete
180-second observation. The XR local state after the crash is unknown, so the
write was not replayed and participant deletion was not attempted. This is an
observed failure of this fixture/run, not proof that the public participant-add
capability is unsupported. Apple's
[WWDC21 sharing session](https://developer.apple.com/videos/play/wwdc2021/10015/)
explicitly describes permitted participants adding records to shared zones.
A [new supported-API fixture](v02-participant-explicit-members-2026-10-26.md)
subsequently succeeded with explicit assignment to the existing share. This
does not explain or erase the relationship/save-only crash in the first run.

The new run was `308AF787-A134-45F1-BAE5-3CE8709FBEE9`, initial mutation
case `5A4B187D-E5A2-4C0B-B81C-79362CC5783C`, and separate read-only
resume/deletion case `C568D27B-BA0E-4FED-9918-418DCEA7E4BC`. Detailed
stages, bounded reports and provenance are in the Demo
[laboratory result](https://github.com/bbruno84/GraphEvoDemo/pull/1). The
private archive `2026-10-26-V02-mutations-5A4B187D-E5A2-4C0B-B81C-79362CC5783C`
contains the protected evidence and crash log outside Git. No production
container, personal account or unrelated app data was changed.
