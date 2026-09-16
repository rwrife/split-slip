# Issue #1 bootstrap evidence

Dated record of what was actually verified, where, and what remains CI-only.

## What this bootstrap adds

- `SplitSlip.xcodeproj` with shared `SplitSlip` scheme (app + UI-test targets).
- `App/`: SwiftUI launch-only placeholder wired to `Packages/ReceiptDomain`.
- `Packages/ReceiptDomain`: pure Swift 6 package holding published MVP contract
  bounds (limits, two-decimal currencies, participant identity, allocation basis)
  with swift-testing unit tests.
- `UITests/SplitSlipLaunchTests.swift`: simulator launch smoke test.
- `Scripts/`: pinned toolchain selection, simulator selection/boot helpers with
  bounded subprocess timeouts, and the CI entrypoint `Scripts/ci.sh`.
- `.github/workflows/ci.yml`: exact-head checkout, pinned-SDK simulator
  validation, always-upload artifacts on `macos-15`.

## Toolchain enforcement

`toolchain.json` pins Xcode 26.0.1 (17A400) / iPhoneOS SDK 26.0 / Swift 6 mode /
deployment target 26.0, exactly as the README and PLAN require. `Scripts/select_xcode.py`
measures `xcodebuild -version` and `xcrun --sdk iphoneos --show-sdk-version` for every
installation under `/Applications` and only accepts an actual version/build/SDK match;
a missing pin is a hard CI failure (`PinError`), never a silent fallback. The workflow
checks out `github.event.pull_request.head.sha` explicitly, so CI tests the exact PR
head commit, not a synthetic merge ref.

`Scripts/ci.sh` enforces iPhone-only policy twice: the project sets
`TARGETED_DEVICE_FAMILY = 1` in every app/UI-test configuration, and after the build
the `device_family_guard` phase converts the built `SplitSlip.app/Info.plist` to JSON
and fails unless `UIDeviceFamily == [1]`. `app-info.json` is uploaded as an artifact.

All simulator subprocesses are bounded (30 s enumeration, 120 s boot, 180 s
bootstatus) with logs preserved in `build/ci-artifacts`, and the workflow uploads
artifacts with `if: always()` so failures keep their provenance
(`provenance.txt` records expected/actual SHA, phase, and exit status).

## Verification actually performed

Linux executor (this host has no Swift/Xcode toolchain):

- `python3 -m unittest discover -s Scripts/tests -v` — helper tests for bounded
  boot/timeout/exit-code behavior, simulator selection, and exact Xcode pin
  selection all pass locally.
- `bash -n Scripts/ci.sh` — syntax check passes.
- Workflow YAML parses; `git diff --check` clean.
- Swift sources could **not** be compiled or tested locally: no `swift`/`swiftc`
  binary exists on this Linux runner. The `ReceiptDomain` test suite and the
  native simulator build/launch are therefore **CI-pending**, not claimed here.

Hosted macOS CI (macos-15, exact PR head): the authoritative evidence for
Xcode/SDK pin measurement, domain tests, simulator build, launch UI test, and the
`UIDeviceFamily == [1]` guard is the CI run for this PR's head commit, retained in
the `ios-ci-<sha>` artifact. Its results are recorded on the PR, not pre-declared here.

## Explicit non-claims

- No physical-device, VoiceOver, or signed-archive evidence exists or is claimed.
- No TestFlight/upload path exists (issue #7 owns that).
- The simulator test proves launch + home-screen rendering only; product journeys
  arrive with issues #2 and #3.
- Hosted `simctl` startup has known transient hangs; a red CI run at a proven
  unchanged tree is retried once before being reported as an environment blocker.
