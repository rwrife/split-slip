# Issue #4 evidence: reference image + accessible workspace continuity

Date: 2026-09-22 (PR head recorded in the PR itself)
Toolchain of record: Xcode 26.0.1 (17A400) / iOS SDK 26.0 / Swift 6 mode
(`toolchain.json`). The executor host is **Linux** — it cannot build, boot a
simulator, or run any Apple binary. Everything below is labelled by evidence
class; nothing is upgraded between classes.

## What landed

- **Reference image pipeline** (`ReceiptDomain/ReferenceImage.swift`,
  `SplitSlipCore/ReferenceImageSandbox.swift`):
  - PhotosPicker is used for *selected* assets only — no camera entitlement,
    no `PHPhotoLibrary` request, photo library access is limited to the
    system picker (`PHPickerConfiguration` semantics via `PhotosPicker`).
  - Payloads are signature-detected, size-bounded (12 MB), and stored only
    after sanitization: JPEG inputs are always run through a deterministic
    structural metadata stripper (all APPn/EXIF/XMP/ICC/Comment segments
    deleted, output re-verified for SOF/SOS/EOI); on Apple platforms an
    ImageIO re-encode to a fresh JPEG runs first (decode+encode never
    copies metadata). PNG/GIF/BMP/TIFF/HEIC are transcoded to JPEG through
    ImageIO where available; a payload that cannot be safely stripped is
    refused with visible copy and the previous reference is untouched.
  - Storage is app-private (`Application Support/SplitSlip/references`),
    owner-only permissions, atomic temp-file-then-move replacement, UUID
    file names with a fail-closed path-containment guard.
  - PhotosPicker cancel → no-op; unloadable/evicted asset → visible refusal
    ("That photo could not be read…"), never a crash and never silent.
- **Receipt/People tabs + reconciliation bar** (`App/ReceiptEditorView.swift`):
  the selected tab, selected line/adjustment, selected person and the
  reference viewport (zoom, offset) live in `WorkspaceSelection` inside
  `ReceiptWorkspaceModel` — never in view-local `@State` — and persist per
  receipt through `FileContinuityStore` (atomic JSON in the sandbox).
  Selection survives tab switches, rotation and relaunch (UI journey below).
  Viewport damage on restore (NaN/Inf/out-of-range) is clamped, not trusted.
- **Continuity ownership rules**: finalization transfers the reference image
  and selection to the snapshot id and releases the draft keys; duplicate-to-
  correct copies them to the fork; canceling a correction releases only the
  fork's keys and leaves the snapshot byte-identical (unit-tested).
- **Accessibility posture**: every state change has text/symbol companions
  (Selected checkmark + "Person:/Line:" bar text, never color-only); all
  reference navigation is available through explicit buttons (zoom in/out,
  reset, four pan directions, 44pt min-height rows); the picker, finalize,
  remove and select flows are plain buttons/toggles; no custom animations
  exist, so Reduce Motion has nothing to suppress; Dynamic Type flows
  through standard `Text`/`Label`/`List` styles; reading order follows
  header → reference → lines → adjustments (Receipt tab) and people →
  review (People tab).

## Evidence by class

### Static (Linux executor, this host)

- `swift build` + `swift test` of `Packages/ReceiptDomain` in container
  `swift:6.2-noble` (Swift 6.2, Swift 6 language mode for the package):
  **72 tests / 12 suites passed**, including the 18 new issue #4 tests:
  - metadata stripper removes EXIF/GPS/XMP/APP14/Comment/JFIF markers from
    synthetic JPEG fixtures and no leaked ASCII survives in output;
    stripping is deterministic and idempotent; truncated/length-corrupt
    JPEGs fail closed (`failedVerification`);
  - format detection (JPEG/PNG/GIF/BMP/TIFF/HEIC/unknown) and refusal of
    unrecognized payloads;
  - reference store round-trip, per-receipt isolation, empty/oversized
    refusal preserving the previous file, snapshot/fork copy semantics;
  - `WorkspaceSelection` clamping (NaN zoom → 1.0, ±Inf offset → clamp),
    in-memory and file continuity relaunch simulation, corrupt continuity
    file degrading to empty without touching receipt data;
  - model-level: import keeps previous image on failure, nil-payload (picker
    cancel) no-op, selection restored by a rebuilt model, finalize transfers
    image+selection, correction cancel releases fork keys only.
- `TARGETED_DEVICE_FAMILY = 1` retained in all four app/UITest build
  configurations of `SplitSlip.xcodeproj` (no `1,2` anywhere); no new
  Info.plist permission keys were added (PhotosUI selection picker needs no
  `NSPhotoLibraryUsageDescription`).

### Simulator (pinned macOS CI — pending on this PR, NOT claimed)

`.github/workflows/ci.yml` on `macos-15` pins Xcode 26.0.1 (17A400)/iOS SDK
26.0 via `Scripts/select_xcode.py` and runs, at the exact PR head SHA:
domain tests, app build, **built-app `UIDeviceFamily == [1]` guard**, and
UI tests. The new UI journey
`testReferenceViewportAndSelectionSurviveNavigationRotationAndRelaunch`
drives a deterministic seeded draft (`-seed-workspace`, in-process-rendered
red JPEG — no binary fixtures) and asserts zoom/pan/line-selection survive
tab switch, simulated rotation (`XCUIDevice.shared.orientation`) and a full
terminate/relaunch; the updated issue #3 journey additionally asserts the
non-color-only selection indicator. **The head-SHA simulator run is the
gate; check the PR's Checks tab before believing any simulator claim.**

### Physical iPhone (separate acceptance gate — explicitly NOT done)

- Real-device VoiceOver pass on the new tabs/bar/viewport labels
- Real PhotosPicker sheet (permission-sheet-free), large-library asset
  eviction behavior, real camera photo metadata verification end-to-end
- Real device rotation (vs. simulated) and app-termination behavior

These remain **open** per the issue text; a simulator run does not close
them and no checklist item here is marked complete on simulation alone.

## Future dual-screen note (issue #4 acceptance, documentation-only)

`ReceiptWorkspaceLayout` remains a *future* adapter: when public dual-safe-
region APIs exist on a real device, the two surfaces that already exist as
independent state — the reference/receipt surface and the people/allocation
surface — map one-to-one onto native safe regions, because selection,
draft edits and the viewport already live in `WorkspaceSelection` above any
layout. **No fold/hinge APIs are referenced or guessed; no iPad target is
built.** Today's tab bar + reconciliation bar is the complete workflow on
ordinary iPhones, and the code must not infer fold state from window size.

## Remaining acceptance gaps for #4

1. Simulator run at head SHA (CI, automatic).
2. Physical iPhone VoiceOver + PhotosPicker + metadata spot-check (manual).
3. Apple-platform behavior of the ImageIO transcode branch (compiles in CI;
   exercised on simulator by the seeded-image import journey only through
   the store path — a device photo check belongs with gate 2).
