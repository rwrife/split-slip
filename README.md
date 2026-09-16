# Split Slip

Local-first iPhone receipt splitter for shared meals and purchases: assign items to people, reconcile every cent, and share clear totals without accounts or payments.

## Status

**Native bootstrap landed (issue #1); product features remain planned.** The repository now contains a real SwiftUI iPhone app, a shared `SplitSlip` scheme, the pure Swift `Packages/ReceiptDomain` package with contract tests, device-family/SDK guards, and pinned macOS CI that builds and launches the app in an iPhone simulator. No receipt-entry workflow, persistence, simulator journey beyond launch, signed archive, or TestFlight build exists yet. The milestones below and [PLAN.md](PLAN.md) define the remaining implementation contract, not completed features.

## Why / who

Friends sharing a meal and housemates buying mixed personal/shared groceries often split a total evenly because item-by-item arithmetic is awkward on a phone. Split Slip keeps receipt lines, unresolved allocations, adjustments, and personal totals in one reviewable local session. It is not a bank, debt tracker, payment service, tax calculator, or accounting system.

## Intended workflow

1. Create a receipt, choose USD/EUR/GBP (two decimal places only for the MVP), add participant nicknames, and enter the printed grand total.
2. Manually enter item labels and line totals; optionally attach a reference image with the system Photos picker. No OCR or automatic financial interpretation.
3. Assign each line to one or several people with equal or positive integer-weighted shares. Split identical quantities using weights or separate lines. Unassigned lines stay visibly unresolved, never silently assigned to everyone.
4. Enter printed tax, service charge, gratuity, or discount as explicit adjustments with selected recipients and an equal/weighted allocation basis. The app does not infer tax law, calculate restaurant gratuities, or choose a basis for the user.
5. Review per-person totals beside the remaining receipt difference. Finalize only when all rows are assigned and the computed total equals the entered receipt total.
6. Share a reviewed plain-text/CSV summary; save a private versioned backup; reopen a draft or explicitly duplicate a finalized snapshot to correct it.

Example uses: two friends sharing one appetizer but not drinks; housemates dividing a bulk grocery line by quantity; one person declining a shared purchase while the rest split it.

## MVP

- Local receipt drafts, participant nicknames, line/adjustment editing, and explicit split weights.
- Deterministic integer-minor-unit arithmetic and visible rounding-cent explanations.
- Unassigned amount and grand-total reconciliation before immutable finalization.
- Person-focused review, accessible non-drag controls, safe draft recovery.
- Optional private receipt image, data deletion, JSON/folder backup and restore, text/CSV sharing.

**Non-goals:** accounts, cloud sync, payment links, bank/contact access, currency conversion, non-two-decimal currencies, OCR, receipt scraping, percentage-based tax/tip engines, cross-receipt balances, notifications, AI, Android/desktop, native iPad support, and commercial bookkeeping/compliance claims. This is an arithmetic organizer, not financial or tax advice; users review inputs and settlements independently.

## Platforms and dual-screen design target

Primary required platform: **iOS 26.0+**, native SwiftUI with Swift 6. Build/CI must use the **iOS 26 SDK or newer**, initially pinned to Xcode **26.0.1 (17A400)** / iOS SDK **26.0** in [toolchain.json](toolchain.json). Toolchain changes require a reviewed pin update and actual native evidence.

The MVP is a **standard iPhone-only app with native iPad support disabled**. Every app-target configuration must set `TARGETED_DEVICE_FAMILY = 1`, never `1,2`; generator settings must preserve the same restriction. On an Apple build host verify the built app's `UIDeviceFamily` is `[1]`. Linux source/config checks cannot verify an archive. No iPad screenshots, multitasking, iPad-specific UI, or iPad release tests are required. iPhone compatibility mode on iPad is not native iPad support; tablet work needs explicit user opt-in.

**iPhone Duo / dual-screen is a future design target, not a claim of hardware or SDK compatibility.** A persistent receipt/reference surface beside person allocations reduces navigation and makes disputed line assignments inspectable while totals remain visible. Today, Receipt and People tabs plus a compact reconciliation bar provide the complete workflow on ordinary iPhones. Domain selection and draft state live above layout, not inside a screen. A future `ReceiptWorkspaceLayout` adapter may map those two surfaces into platform-supported safe regions when public APIs exist. Preserve the selected line, focused participant, draft edits, and reference viewport through layout transitions. No unavailable fold APIs, hinge assumptions, inferred fold state, or automatic iPad enablement.

## Privacy, permissions, and ownership

- SwiftData in the app sandbox, with a pure Swift arithmetic/domain package. No backend, telemetry, analytics, ads, CloudKit entitlement, or app-initiated network dependency.
- Receipt: UUID, currency, expected total, ordered participants, ordered lines/adjustments and allocation weights, draft/final status, schema version. Monetary values are signed 64-bit minor units with validated limits; never binary floats. Final snapshots preserve allocation results and rule version.
- Images are optional. Use PhotosPicker (only selected assets; no broad library access) and copy a metadata-stripped re-encoded image into app-private storage. No camera, microphone, location, contacts, notification, or motion permissions. File import/export is user initiated; a selected Files provider may itself use cloud services.
- Private versioned folder backup contains JSON plus optional sanitized images and a manifest; export warns about names, amounts, and receipt content. Shared summaries exclude images/internal IDs by default and always offer preview. CSV cells are hardened against spreadsheet formula injection.
- Restore validates versions, sizes, IDs, referential integrity, amounts, paths, and totals before staging an atomic replacement, with a pre-restore backup and cancellation. No automatic merges.
- Delete receipt removes owned images; delete-all removes local data. Exported copies and OS device backups remain under user control. App sandbox protection is not a claim of a separately encrypted vault. Document OS backup behavior before release.

Accessibility: Dynamic Type through accessibility sizes, VoiceOver labels and reading order, 44-point controls, no color-only unresolved states, Reduce Motion, locale-aware amount entry without locale-dependent arithmetic, and button/list alternatives to all gestures.

## Development quickstart

Currently: `git clone https://github.com/rwrife/split-slip.git`, then read `PLAN.md` and issues #1–#7. The native bootstrap exists: see `docs/bootstrap-evidence.md` for what is verified and what is CI-pending. On a Mac run `Scripts/ci.sh "$(git rev-parse HEAD)"` after `Scripts/select_xcode.py --toolchain toolchain.json` resolves an exact Xcode 26.0.1 (17A400) / iOS SDK 26.0 installation; a missing pin is an environment blocker, never an excuse to use an older SDK. A Linux executor may run `python3 -m unittest discover -s Scripts/tests -v` and parse checks, but cannot substitute that for iOS simulator/UI validation. Keep signing material out of git.

## Milestones and distribution

1. Native skeleton, enforced device family and SDK pin, CI (#1).
2. Exact arithmetic/domain/persistence (#2).
3. Complete manual-entry to finalized-receipt workflow (#3).
4. Optional reference image and accessible workspace continuity (#4).
5. Private backup/restore, reviewed export and deletion (#5).
6. Integration, adverse-input and real iPhone evidence (#6).
7. Signed release candidate and TestFlight/App Store path (#7).

Bundle ID: `com.infinityball.splitslip`. App Store Connect registration on 2026-09-16: **`CREATED com.infinityball.splitslip`**. Actions secret names verified: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, `ASC_TEAM_ID` (signing/provisioning team). Values are never committed or documented.

Bundle registration and secrets are not an app listing or signing setup. The release issue must establish app record, distribution signing/profiles, export options and a protected manually triggered upload using those secrets, then retain actual archive, device-family, upload and processing evidence. Only iPhone store assets are in scope. Do not claim TestFlight availability until Apple processing succeeds; do not auto-submit to public App Store review without approval.

MIT licensed; see [LICENSE](LICENSE).
