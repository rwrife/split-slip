# Issue #3 evidence — manual entry through reviewed finalization

Dated record of what was actually verified, where, and what remains CI-only.

## What this change adds

- `Packages/ReceiptDomain` gains a third product, `SplitSlipCore`:
  - `ReceiptWorkspaceModel` (`@Observable`) — the whole create → allocate →
    reconcile → finalize lifecycle: raw text fields kept separate from stored
    amounts, auto-save of every valid edit, per-field validation copy,
    equal/weighted recipient assignment, participant removal that flags
    affected rows, mismatch visibility, finalization gating with named
    blockers, snapshot freeze, duplicate-to-correct forking, and
    data-loss-free correction cancellation. All arithmetic delegates to
    `ReceiptDomain`; the model never computes money itself.
  - `DomainMessages` — the single mapping from every domain error case to
    visible copy (tests pin the strings the UI shows).
  - `InMemoryReceiptStore` — protocol-exact store for tests.
- `App/`: `SplitSlipRootView` (home list of drafts + finalized snapshots,
  store-failure screen), `ReceiptEditorView` (currency, printed total,
  people, lines, adjustments, per-row allocation editor, person review with
  extra-cent explanations), `SnapshotDetailView` (read-only finalized review
  + Duplicate-to-correct). Bootstrap placeholder removed. The app wires the
  shipped `SwiftDataReceiptStore`; a `-reset-store` launch argument is used
  **only** by UI tests to start from an empty sandbox.
- `UITests/SplitSlipJourneyTests.swift` replaces the launch smoke test:
  create → allocate → mismatch → correct → finalize → relaunch → inspect →
  duplicate, plus a validation/destructive-removal test. Button/tap based —
  no drag-only interactions.
- iPhone-only policy untouched: `TARGETED_DEVICE_FAMILY = 1` in every
  configuration; the CI `UIDeviceFamily == [1]` guard still re-proves it.

## Verification actually performed

Linux executor (this host has no Swift/Xcode toolchain):

- `swift test` inside `docker run swift:6.2-noble` on the exact package
  sources: **54 tests in 8 suites pass** (40 pre-existing + 14 new
  `SplitSlipCoreTests` covering the happy path, extra-cent explanation,
  adjustments, invalid/empty/negative/zero input copy, mismatch and
  unresolved-row blockers, participant limit, removal-with-review-flagging,
  draft recovery from store, snapshot immutability, correction fork +
  cancel, and injected store failure).
- `python3 -m unittest discover -s Scripts/tests -v` — helper tests pass.
- `SplitSlip.xcodeproj/project.pbxproj` audited programmatically: no
  duplicate object ids, no references to undefined ids, every build-file
  phase entry defined, every referenced source path on disk.
- `bash -n Scripts/ci.sh` and `git diff --check` clean.

Native UI Swift files (`App/*.swift`, `UITests/*.swift`) could **not** be
compiled locally — there is no iOS SDK on Linux. Their correctness is
CI-pending, not claimed here.

## Explicit non-claims

- The native iPhone UI journey, simulator build, and `UIDeviceFamily == [1]`
  guard are proven only by the hosted macOS CI run at this PR's exact head
  SHA (`ios-ci-<sha>` artifact). Results land on the PR, not in this file.
- No physical-device, VoiceOver, or signed-archive evidence exists (issues
  #4/#6/#7 own those).
- Hosted `simctl` startup has known transient hangs; a red CI run on a
  proven unchanged tree is retried once before being reported as an
  environment blocker.

## Acceptance mapping (issue #3)

- [x] Draft create/open, currency, nicknames, expected total, manual item totals, validation + empty/error states (model + editor; core tests).
- [x] Equal/weighted shares to explicit recipients, positive fees / negative discounts, per-person review with unresolved amounts and extra-cent explanations (core tests + review UI).
- [x] Total difference visible; finalization blocked until invariants hold; participant-deletion confirmation (`editor.removeParticipant.*` alert).
- [x] Finalized snapshot read-only; duplicate-to-correct preserves the original and cancels without data loss (core tests + journey test).
- [~] Native UI journey covered by `SplitSlipJourneyTests` — **execution is CI-pending**; native iPad support stays disabled, no drag-only interactions.
