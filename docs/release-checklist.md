# Release evidence gates (#6 and #7)

Do not close the release issues based on source code or a successful simulator build alone.

## Implemented release path

`.github/workflows/release.yml` is manually dispatched from main. It checks that the `testflight` environment exists and has required reviewers, requires a device/CI evidence URL, runs exact-SHA pinned native CI, then invokes `Scripts/release.sh`. The script uses the four existing `ASC_*` repository secrets, creates a private temporary API-key file with cleanup, verifies the pinned toolchain, archives, verifies the signature, bundle ID, and `UIDeviceFamily == [1]`, and exports an IPA with provenance. Upload is an explicit input defaulting to false. No workflow submits to public App Store review.

A configured key is not proof of certificate/profile permissions. GitHub environment access, App Store agreements, signing assets, and an app record must be verified by the account owner. Missing protection or unavailable exact Xcode pin fails the workflow. An upload response is not proof that Apple processing finished.

## Still required before release

- [ ] Configure required reviewers on the `testflight` GitHub environment; verify protection and repository policy cannot bypass the intended gate.
- [ ] Confirm the App Store Connect app record for `com.infinityball.splitslip`, agreements, distribution signing/provisioning access, and a build number newer than any existing Apple build.
- [ ] Review exact-head pinned CI artifacts: Xcode 26.0.1 (17A400), SDK 26.0, domain tests, simulator UI journeys, built device family, and failure diagnostics.
- [ ] Real iPhone: record device model, iOS build, app SHA/build number, VoiceOver reading order, accessibility text, rotation, selected-photo import/cancellation, denied/unavailable assets, and termination/relaunch recovery.
- [ ] Real iPhone: text and CSV share sheets; backup save, selected Files-provider import, restore cancellation, successful restore with photos, and delete-all. Repeat offline. Verify exported names/amounts match the preview.
- [ ] Inspect permissions and entitlements; verify no runtime network dependency. Check photo exports for EXIF/location metadata.
- [ ] Retain a real signed archive, IPA, signature verification, `[1]` device family, and provenance.
- [ ] If uploaded, record the Apple build identifier, upload response, and successful processing/TestFlight status. Resolve encryption/export-compliance questions in the owner account.
- [ ] Prepare actual iPhone screenshots, app description, and hosted support/privacy URLs based on `docs/support.md` and `docs/privacy.md`.
- [ ] Obtain explicit owner approval before public App Store submission.

Local Xcode 27 simulator evidence is supplemental. It does not replace the pinned CI or real-device gates. The release workflow has been prepared but has not been executed or uploaded by this task.
