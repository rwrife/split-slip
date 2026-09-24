# Sharing, data ownership, and layout evidence

Work continues from merged PR #12 (`12fdbe0`). Issues #5–#7 remain open until their native/device/release acceptance criteria are met.

## Implemented

- Warm, adaptive receipt cards; search by item/person; full-card hit targets; prominent totals; person badges; reviewed finalized summaries; accessible item-removal controls.
- Preview all-person or selected-person text/CSV, share explicitly through the system sheet, or save CSV to Files. Text cells are quoted and formula-leading input is neutralized. Photos/internal UUIDs do not enter shared summaries.
- A version-1 folder backup with manifest, receipt JSON, and optional sanitized JPEGs. Validation rejects unsupported versions/currencies, duplicate identities, unknown rows/recipients, invalid weights and amounts, inconsistent finalized totals, unexpected paths, symlinks, and excessive sizes. Imports are fully staged before replacement confirmation.
- Transactional SwiftData collection replacement plus a durable cross-store recovery journal. A pre-restore folder remains exportable; failure and interrupted-restore recovery preserve original receipts. Successful restore resets workspace preferences; rollback restores prior selections.
- Confirmed receipt/all-data deletion, owned-photo cleanup, orphan-photo cleanup on delete-all, and removal of recovery copies. Exported copies and OS backups are explicitly outside deletion scope.
- Draft-to-finalized transitions use one database transaction. Photo copy failure prevents finalization; stored corruption/fetch failures surface errors rather than an empty library.
- Corrected JPEG DRI/DNL segment handling, strict real-image decoding on Apple, bounded 48 MP input/4,096-pixel working image, orientation application, and removal of metadata after re-encoding. Image replacement no longer deletes the original before writing its replacement.
- Protected manual release workflow and privacy/support/release-checklist documents. The release workflow has not been executed.

## Local verification, 2026-09-23 (America/Los_Angeles)

Host: Xcode **27.0 (27A266a)**, SDK **27.0**. This is supplemental evidence; the project pin remains **26.0.1 (17A400), SDK 26.0**. The pin selector explicitly reports that the required installation is absent. Existing local Xcode signing/project settings were preserved and excluded from the feature commit.

- **92 Swift tests passed**: 41 core tests and 51 domain/store tests. Cases include exact-cent exports, CSV injection/escaping, empty-draft + finalized backup round trip, real photo backup/deletion, unsupported data, symlinks/traversal/size bounds, tampered shares, injected replacement failure, process-interruption recovery, damaged orphan-photo deletion, durable SwiftData replacement, and corrupt-store reads without erasure.
- **21 Python helper tests passed**.
- Native simulator build passed; built `UIDeviceFamily == [1]` and bundle identifier `com.infinityball.splitslip` were verified.
- Four native journeys passed on **iPhone 18 Pro / iOS 27.0**: manual entry through finalization/preview/relaunch/correction, confirmed deletion/relaunch, reference selection/viewport continuity, and validation/participant-removal confirmation.
- Five native journeys passed on **iPhone 17e / iOS 26.5**, adding largest-accessibility-text layout and canceled native Files operations. Visual inspection caught an ineffective initial dark-mode launch override; an explicit simulator-only appearance override and simplified accessibility header were then added. The final create/finalize/preview, deletion, and accessibility/Files-cancellation journeys all passed again. Final screenshots confirm actual dark appearance and the simplified header.
- Release workflow YAML parses; `Scripts/release.sh` passes `bash -n`. Signing/export/upload were **not run**.
- GitHub metadata check found all four expected secret **names**; values were not read. Only the unprotected `copilot` environment exists. A protected `testflight` environment is an explicit release blocker.

The retained results are local `.xcresult` bundles under `/private/tmp/split-slip-*.xcresult`; these are not committed. The normal-size home screenshot in `docs/screenshots/home-simulator.png` is an actual simulator capture, not a design mockup.

## Still open

Exact-head pinned CI after push; successful end-to-end native Files-provider save/restore and native share completion (current native tests cover preview and cancellation, while package tests cover round trips); actual iPhone VoiceOver/PhotosPicker/Files/offline/termination evaluation; protected release environment; confirmed App Store record/agreements/signing; a signed archive/IPA; and Apple processing evidence. No TestFlight or App Store availability is claimed.
