# App Store assets

These screenshots show implemented receipt-entry and finalization flows, captured from the running app with fictional participants Ana and Bo sharing a $30 lunch. The app is sufficiently implemented for these captures despite having five merged PRs at the time of preparation. These assets do not assert that every planned release milestone is complete.

## Screenshots

1. `screenshots/iphone-6.5/01-receipt-editor.png` — entered receipt and assigned item.
2. `screenshots/iphone-6.5/02-receipts.png` — saved finalized receipt.
3. `screenshots/iphone-6.5/03-person-totals.png` — read-only per-person totals.

Capture device: iPhone 11 Pro Max, iOS 26.5 simulator, native portrait 1242 × 2688. Exported as opaque RGB PNGs without interface alteration, frames or marketing overlays. App source baseline: `12fdbe08addc7382e5bb55c0ae76163dedcc99fe`. Xcode 27.0 was used for this local simulator verification; this does not change the repository's CI toolchain pin.

## Reproduction

The `testAppStoreScreenshots` UI journey in `UITests/SplitSlipJourneyTests.swift` creates the sample receipt through the real controls and attaches the three screenshots to the test result. It resets the app's local store, so use a dedicated simulator.

For clean captures, restart the dedicated simulator first to clear any other-app navigation breadcrumb, then set the simulator status bar to 9:41 with full battery and Wi-Fi.

Run `xcodebuild test -project SplitSlip.xcodeproj -scheme SplitSlip -destination 'platform=iOS Simulator,id=<6.5-inch-simulator-UUID>' -resultBundlePath /tmp/SplitSlipScreenshots.xcresult -only-testing:SplitSlipUITests/SplitSlipJourneyTests/testAppStoreScreenshots CODE_SIGNING_ALLOWED=NO`.

Export attachments with `xcrun xcresulttool export attachments --path /tmp/SplitSlipScreenshots.xcresult --output-path /tmp/SplitSlipAttachments`, select the three named captures, and export as RGB without resizing. Inspect each before replacing repository assets.

`description.txt` describes implemented features only. Backup/export and other unimplemented roadmap features are not advertised. No signed archive, App Store upload or submission was performed in this preparation step.
