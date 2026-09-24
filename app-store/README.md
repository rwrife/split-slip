# App Store assets

Refreshed September 24, 2026 from the running app with fictional participants Ana and Bo. The screenshots show the current quick-split, fixed-amount, item-assignment, deletion, and expandable finalized-detail interfaces.

## Screenshots

- `screenshots/iphone-6.5/01-receipt-editor.png` — item assignments with stationary person switches and counters on the left.
- `screenshots/iphone-6.5/02-receipts.png` — saved receipts with a visible delete action.
- `screenshots/iphone-6.5/03-person-totals.png` — a finalized person expanded to show their item amount.
- `screenshots/iphone-6.5/04-quick-split.png` — the default receipt-total item and receipt-wide equal split action.
- `screenshots/iphone-6.5/05-custom-amounts.png` — a fixed $10 share and an automatic $20 remainder.

Capture device: a dedicated iPhone 11 Pro Max / iOS 26.5 simulator, native portrait 1242 × 2688. Files are opaque RGB PNGs with no resizing, interface alteration, frames, or marketing overlays. The images were refreshed alongside the PR #13 usability changes. Xcode 27.0 was used for local capture; the repository's CI toolchain pin remains unchanged.

## Icon

`App/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png` uses the artwork supplied by the user on September 24. The complete square artwork is resized to 1024 × 1024 and stored as opaque RGB; iOS applies its normal icon mask.

## Reproduction

`testAppStoreScreenshots` creates the sample through the app's controls and attaches all five screenshots. It resets local app data, so use a dedicated simulator. Boot it cleanly, then set the simulator status bar to 9:41, full battery, and Wi-Fi.

Run `xcodebuild test -project SplitSlip.xcodeproj -scheme SplitSlip -destination 'platform=iOS Simulator,id=<6.5-inch-simulator-UUID>' -derivedDataPath /tmp/SplitSlipCaptureBuild -resultBundlePath /tmp/SplitSlipScreenshots.xcresult -only-testing:SplitSlipUITests/SplitSlipJourneyTests/testAppStoreScreenshots CODE_SIGNING_ALLOWED=NO`.

Confirm the result contains one passed test and five named attachments. Export with `xcrun xcresulttool export attachments --path /tmp/SplitSlipScreenshots.xcresult --output-path /tmp/SplitSlipAttachments`. Convert to RGB without resizing and inspect each image before replacing the repository assets.

`description.txt` describes the implemented flows. These assets do not claim release acceptance is complete. No signed archive, App Store upload, or submission was performed.
