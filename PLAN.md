# Split Slip implementation plan

## Scope and architecture

A local iPhone receipt-allocation workspace, not a payment or debt service. Primary iOS 26.0+, Swift 6, SwiftUI for native accessibility, SwiftData for sandbox persistence, Foundation/Codable for versioned backup, PhotosPicker for optional user-selected reference image. No runtime third-party dependencies needed initially. A pure Swift package owns money parsing, allocation, reconciliation, validated snapshots and restore validation; UI and storage adapt it without reimplementing financial rules.

The native app implements manual splitting, immutable review, photo references, and workspace continuity. Sharing/data ownership and release gates are tracked in issues #5–#7 and the evidence documents. Initial toolchain pin: Xcode 26.0.1 (17A400), iOS SDK 26.0 in toolchain.json. CI must verify executable version/build and SDK, not trust an application directory name. If absent, report an environment blocker; never silently use an older SDK or assert build success.

## Device support contract

Standard iPhone app; **native iPad support disabled by default**. Set `TARGETED_DEVICE_FAMILY = 1` in all app configurations and consistent generator settings. Inspect built `UIDeviceFamily = [1]` in simulator output and signed archive on macOS. Linux can only verify source policies, not actual archives. No iPad screenshots, tablet UI, multitasking or iPad release testing in MVP. iPad enablement requires explicit opt-in; iPhone compatibility mode on iPad is different.

Future iPhone Duo value: receipt/reference remains visible on one surface, person allocations and adjustments on the other. Today: Receipt/People tabs, a reconciliation bar and one shared `ReceiptWorkspaceState`. `ReceiptWorkspaceLayout` is a future safe-region adapter, not a fold detector. Preserve receipt ID, selected line, participant, draft edits and reference viewport during navigation/rotation. Defer native dual-screen migration until usable public SDK/device evidence exists; do not infer hardware capabilities from screen width or implement a tablet target by stealth.

## Domain rules (test before UI)

- MVP currencies USD/EUR/GBP, all exponent 2, fixed per receipt once rows exist. Reject unsupported currencies rather than silently apply cents to every currency.
- Parse decimal strings strictly with explicit locale rules into Int64 minor units. Reject ambiguous grouping, extra precision, non-finite data, malformed input and overflow. Bound a receipt to 200 lines, 50 adjustments, 30 participants and absolute total 100,000,000 minor units. Bound positive integer weights to 1..1000. Validate every import before multiplication; use checked arithmetic.
- Item amounts nonnegative. Adjustments may be positive fees or negative discounts, all entered as printed amounts. No inferred percentages, tax treatment or gratuity base. Each adjustment has explicitly selected recipients and weights; no silent fallback to everyone. Block finalization for a negative participant total.
- Allocate absolute magnitude by integer division of amount times weights over sum(weights). Award residual cents to largest fractional remainders, breaking ties by stored participant order, then restore the amount sign for negative adjustments. Participant UUIDs and saved order make output repeatable across restarts; reordering participants changes tie priority and must be visible. Display any extra cent beside its reason.
- Every allocated row sums exactly to its row amount. A line with no recipients is unresolved, not zero-cost or evenly shared. Removing a participant requires confirmation and leaves affected rows needing review; never silently reassign cost.
- Computed receipt total = sum(items) + sum(adjustments); difference = entered expected grand total minus computed total. Finalize only when difference is zero, all rows have valid allocations, totals are nonnegative, at least one participant/line exists, and sum(person totals) = expected total.
- Finalization atomically stores immutable snapshot + algorithm/schema versions. A correction duplicates to a new linked draft; no hidden mutation of shared results. Draft edits persist transactionally and recover after termination. Empty/malformed stores show explicit errors, never wipe silently.

## Dependency-ordered milestones

| Issue | Goal | Dependencies | Required evidence |
|---|---|---|---|
| #1 | Xcode/Swift package skeleton, device/SDK guard, native CI | none | actual iPhone simulator build/test; generator regeneration retains family 1 |
| #2 | Money/allocation/reconciliation model and local store | #1 | deterministic and randomized conservation, rounding, persistence tests |
| #3 | Manual receipt entry through immutable finalization | #2 | UI journey and restart/correction tests |
| #4 | Image reference + accessible iPhone workspace | #3 | denied/cancel import, large type, VoiceOver, rotation/selection evidence |
| #5 | Backup/restore, export, deletion and privacy | #2, #3, #4 | round-trip, malicious-input, transactional-failure and preview tests |
| #6 | Integrated regression gates and device evaluation | #3, #4, #5 | native CI artifacts + real iPhone checklist with honest gaps |
| #7 | Signed iPhone release/TestFlight handoff | #1–#6 | real archive, UIDeviceFamily [1], processed TestFlight upload or explicit blocker |

## Testing strategy

Unit tests cover a 1-cent row split 3 ways, ties and reordered participants, uneven 1:2 weights, negative discount symmetry, zero values, maximum bounded input, checked-overflow refusal, ambiguous decimal input, unsupported currency, removed participants, unassigned lines, total mismatch, immutable snapshot/correction and storage migration rejection. Property tests use reproducible seeds and independent invariants: row conservation, receipt/person equality, repeatability and quota bounds, not duplicated production formulas as an oracle.

Storage tests use temporary stores only, simulate failures during save/restore, verify restart recovery and retain originals on invalid input. Backup folder import rejects path traversal, absolute paths, symlinks, duplicate IDs, orphan allocations, oversized images/data and unsupported versions. No unbounded archive extraction: folder-based format first. CSV tests protect formula-leading text and quotation/newline edge cases. Metadata tests inspect re-encoded images and exported manifests for location/EXIF leakage.

XCTest/UI journeys on native macOS CI must exercise create → enter → allocate → reconcile → finalize → preview/share → backup/restore. Include compact iPhones, accessibility text sizes, light/dark mode, no-color status, cancellation, app relaunch and orientation. Bound simulator startup and all diagnostics so artifacts upload on failure. Record exact commit SHA, Xcode version/build, SDK and simulator model/OS with xcresult. Real iPhone VoiceOver, PhotosPicker, share sheet and termination checks are separate from simulation; never convert a missing device into a passed checklist. Test network independence and review permissions/entitlements before release.

## Packaging / distribution

Bundle: `com.infinityball.splitslip`; registration result `CREATED com.infinityball.splitslip` on 2026-09-16. Four repository Actions secrets exist by name: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8, ASC_TEAM_ID. Their presence is not proof of certificate/profile access. Issue #7 adds least-privilege CI, explicit protected/manual signing/upload, short-lived key files with cleanup, no secrets on fork PRs, reviewed provisioning and export options, and correct ASC_TEAM_ID usage. Confirm the app record and account agreements, retain a real signed archive + manifest and Apple processing status. State blockers rather than generating fake IPA/build IDs. App Store listing: only iPhone screenshots, local-data privacy policy, accessibility notes, no payment/tax claims; public submission needs owner approval.

## Risks / boundaries

Rounding disputes need explainable allocation and stable priority; input mistakes need reconciliation but cannot prove the receipt was entered correctly. Unknown tax/service-charge treatment belongs to the user, not an invented algorithm. Images can contain sensitive personal information; references never automatically enter shared summaries. Backups can leave the sandbox by explicit user action. No accounts, bank/payments, long-term balances, currency exchange, OCR/AI, tax advice, medical claims, safety role, Android, desktop, tablet support or unsupported fold SDK dependencies in this MVP.
