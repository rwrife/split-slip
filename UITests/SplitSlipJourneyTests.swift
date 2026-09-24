import Foundation
import XCTest

/// Issue #3 acceptance journey (updated for the issue #4 tabbed workspace):
/// create → allocate → mismatch → correct → finalize → relaunch → inspect →
/// duplicate. Issue #4 adds the reference viewport + continuity journey and
/// the tabbed Receipt/People navigation. Button/tap based only for the app
/// itself (no drag-only interactions); the tests may *scroll* the list,
/// which SwiftUI `List` virtualizes when the keyboard changes the offset.
/// Every launch resets the on-disk store with `-reset-store` except the
/// explicit relaunch step, which proves state survives termination.
@MainActor
final class SplitSlipJourneyTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    // MARK: - Helpers

    private func containerExists(_ identifier: String, timeout: TimeInterval = 15, message: String? = nil) {
        // Container identifiers can surface as any element type depending on
        // the SwiftUI backing view; query loosely to stay deterministic.
        let element = app.descendants(matching: .any)[identifier]
        XCTAssertTrue(element.waitForExistence(timeout: timeout), message ?? "container \(identifier) missing")
    }

    /// Alternating bounded list scrolls until an element is hittable. The
    /// app UI needs no gestures; scrolling is test-side navigation only.
    @discardableResult
    private func reveal(_ element: XCUIElement, timeout: TimeInterval = 12) -> Bool {
        if pollHittable(element, seconds: 2) { return true }
        let deadline = Date().addingTimeInterval(timeout)
        var scrollDownFirst = true
        while Date() < deadline {
            if scrollDownFirst { app.swipeDown() } else { app.swipeUp() }
            scrollDownFirst.toggle()
            if pollHittable(element, seconds: 1) { return true }
        }
        return false
    }

    @discardableResult
    private func revealText(_ text: String, timeout: TimeInterval = 12) -> Bool {
        // List rows can merge label+value into one accessibility element
        // ("Ana, 15.00"), so match by substring rather than exact text.
        let element = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", text)
        ).firstMatch
        if element.waitForExistence(timeout: 2) { return true }
        let deadline = Date().addingTimeInterval(timeout)
        var scrollDownFirst = true
        while Date() < deadline {
            if scrollDownFirst { app.swipeDown() } else { app.swipeUp() }
            scrollDownFirst.toggle()
            if element.waitForExistence(timeout: 1) { return true }
        }
        return false
    }

    /// Same scroll-reveal as `reveal` but keyed on existence rather than
    /// hittability. Correct for non-interactive marks (icon-only selection
    /// badges, images): they can exist while never accepting touches, and
    /// `isHittable` would then false-fail a genuinely-present indicator.
    @discardableResult
    private func revealExists(_ element: XCUIElement, timeout: TimeInterval = 12) -> Bool {
        if element.waitForExistence(timeout: 2) { return true }
        let deadline = Date().addingTimeInterval(timeout)
        var scrollDownFirst = true
        while Date() < deadline {
            if scrollDownFirst { app.swipeDown() } else { app.swipeUp() }
            scrollDownFirst.toggle()
            if element.waitForExistence(timeout: 1) { return true }
        }
        return false
    }

    private func pollHittable(_ element: XCUIElement, seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if (try? element.isHittable) == true { return true }
            usleep(250_000)
        }
        return false
    }

    /// Builds a one-line AX report for the reference workspace inside an
    /// assertion message (print() output does not reach the xcodebuild log).
    /// Enumerates the ONE bound snapshot (no per-element re-query) and lists
    /// every editor.* identifier with its frame; when the zoom-in button is
    /// present, additionally lists every element whose frame covers its
    /// center. Guarded so the report itself can never throw.
    private func referenceSubtreeDump(_ why: String) -> String {
        var lines: [String] = ["\(why) window=\(app.frame)"]
        let all = app.descendants(matching: .any).allElementsBoundByIndex
        var zoomFrame: CGRect?
        for el in all.prefix(800) {
            let id = el.identifier
            guard id.hasPrefix("editor.") else { continue }
            lines.append("\(id)\(el.frame)")
            if id == "editor.reference.zoomIn" { zoomFrame = el.frame }
        }
        if let f = zoomFrame {
            let center = CGPoint(x: f.midX, y: f.midY)
            var n = 0
            for el in all.prefix(800) where el.frame.width > 0 && el.frame.contains(center) {
                let id = el.identifier.isEmpty ? "#\(el.elementType.rawValue)" : el.identifier
                lines.append("covers:\(id)\(el.frame)")
                n += 1
                if n >= 14 { break }
            }
        }
        return lines.joined(separator: " | ")
    }

    /// Tap, type, then commit deterministically. The keyboard toolbar "Done"
    /// button appears in some layouts; when it does not (TabView layout),
    /// pressing Return triggers the field's `onSubmit` focus release. Then
    /// wait for the keyboard to actually hide so tab-bar taps stay hittable.
    private func tapAndType(_ element: XCUIElement, text: String) {
        XCTAssertTrue(reveal(element), "element \(element.identifier) never became hittable")
        element.tap()
        element.typeText(text)
        commitKeyboard(element)
    }

    private func commitKeyboard(_ element: XCUIElement) {
        // Keyboard toolbar items can surface as non-Button element types;
        // query any element by identifier before falling back to Return.
        let done = app.descendants(matching: .any)["editor.dismissKeyboard"]
        if done.waitForExistence(timeout: 2), (try? done.isHittable) == true {
            done.tap()
        } else if app.keyboards.count > 0 {
            element.typeText("\n")
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, app.keyboards.count > 0 {
            usleep(200_000)
        }
    }

    /// Switch the editor's TabView to one of its tabs (issue #4 layout).
    /// Tab content can remain in the hierarchy (non-hittable) while another
    /// tab is shown, so confirmation is by hittability of the destination
    /// container, not mere existence. Tapping the already-selected tab is a
    /// harmless no-op.
    private func openTab(_ name: String) {
        let container = name == "People" ? "editor.peopleTab" : "editor.receiptTab"
        let tab = app.tabBars.buttons[name]
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "tab \(name) never appeared")
        for _ in 0..<3 {
            tab.tap()
            let deadline = Date().addingTimeInterval(6)
            while Date() < deadline {
                // Either signal proves the switch: the tab bar item reports
                // selected, or the destination container is hittable.
                if (try? tab.isSelected) == true { return }
                if (try? app.descendants(matching: .any)[container].isHittable) == true { return }
                usleep(250_000)
            }
        }
        XCTFail("tab \(name) never switched to \(container)")
    }

    private func freshLaunch() {
        app.launchArguments = ["-ui-testing", "-reset-store"]
        app.launch()
        containerExists("home.root")
        containerExists("home.empty")
    }

    /// Enter currency stays USD; add two people, one line, and reach a
    /// deliberate total mismatch (rows 30.00 vs printed 20.00).
    private func buildMismatchedReceipt() {
        app.buttons["home.newReceipt"].tap()
        containerExists("editor.root", timeout: 10)
        openTab("Receipt")

        tapAndType(app.textFields["editor.expectedTotal"], text: "20.00")
        openTab("People")
        tapAndType(app.textFields["editor.participantName"], text: "Ana")
        app.buttons["editor.addParticipant"].tap()
        tapAndType(app.textFields["editor.participantName"], text: "Bo")
        app.buttons["editor.addParticipant"].tap()

        openTab("Receipt")
        app.buttons["editor.addLine"].tap()
        tapAndType(app.textFields["editor.line.0.label"], text: "Appetizer")
        tapAndType(app.textFields["editor.line.0.amount"], text: "30.00")

        // Split equally across both people.
        let split = app.buttons["editor.splitEqually"]
        XCTAssertTrue(reveal(split), "split-equally button never became hittable")
        split.tap()

        // Mismatch must be visible in the reconciliation bar (both tabs).
        XCTAssertTrue(revealText("Rows exceed the total by 10.00"))
        XCTAssertFalse(app.buttons["editor.finalize"].isEnabled,
                       "Finalize must stay blocked while totals mismatch")
    }

    // MARK: - Journeys

    func testCreateAllocateMismatchFinalizeRelaunchDuplicate() throws {
        freshLaunch()
        buildMismatchedReceipt()

        // Correct the mismatch: retype the printed total as 30.00.
        // Triple-tap selects the field's current text so typing replaces it.
        let total = app.textFields["editor.expectedTotal"]
        XCTAssertTrue(reveal(total), "expected-total field never became hittable")
        total.tap(withNumberOfTaps: 3, numberOfTouches: 1)
        total.typeText("30.00")
        commitKeyboard(total)
        XCTAssertTrue(revealText("Rows match the entered total"))
        XCTAssertTrue(app.buttons["editor.finalize"].isEnabled)

        // Tab continuity across navigation: select a person, switch tabs and
        // verify the shared workspace selection reports on both (issue #4).
        openTab("People")
        let selectAna = app.buttons["editor.person.Ana.select"]
        XCTAssertTrue(reveal(selectAna), "select-person button never became hittable")
        selectAna.tap()
        XCTAssertTrue(app.staticTexts["editor.bar.selection"].waitForExistence(timeout: 5)
                      || revealText("Person: Ana"))
        let selectedMark = app.descendants(matching: .any)["editor.person.Ana.selected"]
        XCTAssertTrue(revealExists(selectedMark),
                      "selected person needs a non-color-only indicator")
        openTab("Receipt")

        app.buttons["editor.finalize"].tap()

        // Back on home, the finalized receipt is listed.
        XCTAssertTrue(app.buttons["home.snapshot.0"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["home.snapshot.0"].waitForExistence(timeout: 5))

        // --- Relaunch WITHOUT reset: persistence proof ---
        app.terminate()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        containerExists("home.root")
        XCTAssertTrue(app.buttons["home.snapshot.0"].waitForExistence(timeout: 5),
                      "Snapshot must survive app termination")

        // Inspect the snapshot: read-only totals.
        app.buttons["home.snapshot.0"].tap()
        containerExists("snapshot.readonly", timeout: 5)
        XCTAssertTrue(revealText("Ana"))
        XCTAssertTrue(revealText("15.00"))
        XCTAssertTrue(revealText("30.00"))

        // Sharing always starts with a reviewed preview, never an automatic send.
        let share = app.buttons["snapshot.share"]
        XCTAssertTrue(reveal(share))
        share.tap()
        XCTAssertTrue(app.staticTexts["share.preview"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["share.preview"].label.contains("30.00 USD"))
        app.segmentedControls["share.format"].buttons["CSV"].tap()
        XCTAssertTrue(app.staticTexts["share.preview"].label.contains("Person total"))
        let preview = XCTAttachment(screenshot: app.screenshot())
        preview.name = "Reviewed CSV preview"; preview.lifetime = .keepAlways; add(preview)
        app.buttons["Done"].tap()

        // Duplicate-to-correct forks a new linked draft.
        app.buttons["snapshot.duplicate"].tap()
        containerExists("editor.root", timeout: 5)
        XCTAssertTrue(app.navigationBars["Make a correction"].exists)

        // Canceling the correction must keep the snapshot (no data loss).
        app.buttons["editor.cancelCorrection"].tap()
        let alert = app.alerts["Cancel this correction?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Cancel correction"].tap()
        containerExists("home.root", timeout: 5)
        XCTAssertTrue(app.buttons["home.snapshot.0"].waitForExistence(timeout: 5))
    }

    private func cancelFilePicker() {
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.waitForExistence(timeout: 2) { cancel.tap(); return }
        let browse = app.buttons["Browse"].firstMatch
        if browse.exists { browse.tap() }
        if cancel.waitForExistence(timeout: 2) { cancel.tap(); return }
        let close = app.buttons["Close"].firstMatch
        if close.exists { close.tap(); return }
        // Some system Files sheets expose dismissal through the native sheet
        // gesture. This is outside the app's own non-gesture controls.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.09))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
    }

    func testLargeTextDarkLayoutAndCanceledFileOperations() throws {
        app.launchArguments = ["-ui-testing", "-reset-store", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL", "-ui-testing-dark"]
        app.launch()
        containerExists("home.root")
        let home = XCTAttachment(screenshot: app.screenshot())
        home.name = "Home — dark accessibility text"; home.lifetime = .keepAlways; add(home)
        app.buttons["home.data"].tap()
        let backup = app.buttons["data.backup"]
        XCTAssertTrue(reveal(backup)); backup.tap()
        cancelFilePicker()
        let restore = app.buttons["data.restore"]
        XCTAssertTrue(reveal(restore)); restore.tap()
        cancelFilePicker()
        app.buttons["Done"].tap()
        app.buttons["home.newReceiptToolbar"].tap()
        containerExists("editor.root")
        XCTAssertTrue(app.tabBars.buttons["People"].isHittable)
        let editor = XCTAttachment(screenshot: app.screenshot())
        editor.name = "Editor — dark accessibility text"; editor.lifetime = .keepAlways; add(editor)
    }

    func testFixedPersonAmountsAndVisibleReceiptDeletion() throws {
        freshLaunch()
        buildMismatchedReceipt()
        openTab("Receipt")
        let printedTotal = app.textFields["editor.expectedTotal"]
        XCTAssertTrue(reveal(printedTotal))
        printedTotal.tap(withNumberOfTaps: 3, numberOfTouches: 1)
        printedTotal.typeText("30.00"); commitKeyboard(printedTotal)
        openTab("People")
        let amount = app.textFields["editor.person.Ana.amount"]
        XCTAssertTrue(reveal(amount)); tapAndType(amount, text: "10.00")
        XCTAssertTrue(revealText("20.00"))
        app.terminate(); app.launchArguments = ["-ui-testing"]; app.launch()
        app.buttons["home.draft.0"].tap()
        openTab("People")
        XCTAssertTrue(reveal(amount)); XCTAssertEqual(amount.value as? String, "10.00")
        XCTAssertTrue(app.buttons["editor.finalize"].isEnabled)
        app.buttons["editor.finalize"].tap()
        let snapshot = app.buttons["home.snapshot.0"]
        XCTAssertTrue(snapshot.waitForExistence(timeout: 10)); snapshot.tap()
        let person = app.buttons.matching(NSPredicate(format: "identifier == %@", "snapshot.person.0.expand")).firstMatch
        XCTAssertTrue(reveal(person)); person.tap()
        XCTAssertTrue(revealText("Appetizer"))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let delete = app.buttons["home.snapshot.0.delete"]
        XCTAssertTrue(reveal(delete)); delete.tap()
        app.alerts.buttons["Keep receipt"].tap()
        XCTAssertTrue(snapshot.exists)
        delete.tap(); app.alerts.buttons["Delete receipt"].tap()
        app.terminate(); app.launch()
        XCTAssertFalse(app.buttons["home.snapshot.0"].exists)
    }

    func testFinalizedPersonExpandsTheirAssignedItems() throws {
        app.launchArguments = ["-ui-testing", "-reset-store", "-seed-workspace", "ABAAAAAA-0000-0000-0000-000000000001"]
        app.launch()
        app.buttons["home.draft.0"].tap()
        openTab("Receipt")
        tapAndType(app.textFields["editor.expectedTotal"], text: "5.00")
        let selector = app.switches["editor.line.0.person.Ana"]
        XCTAssertTrue(reveal(selector)); selector.tap()
        app.buttons["editor.finalize"].tap()
        let saved = app.buttons["home.snapshot.0"]
        XCTAssertTrue(saved.waitForExistence(timeout: 10)); saved.tap()
        let expand = app.buttons["snapshot.person.0.expand"]
        XCTAssertTrue(reveal(expand)); expand.tap()
        let item = app.descendants(matching: .any)["snapshot.person.0.item.BBBBBBBB-0000-0000-0000-0000000000B1"]
        XCTAssertTrue(revealExists(item), app.debugDescription)
        XCTAssertTrue(revealText("5.00"))
        let expanded = XCTAttachment(screenshot: app.screenshot())
        expanded.name = "Finalized person item details"; expanded.lifetime = .keepAlways; add(expanded)
        expand.tap()
        XCTAssertFalse(item.exists)
    }

    func testFilesBackupDeleteAndRestore() throws {
        app.launchArguments = ["-ui-testing", "-reset-store", "-seed-workspace", "EEAAAAAA-0000-0000-0000-000000000001"]
        app.launch()
        containerExists("home.root")
        app.buttons["home.data"].tap()
        app.buttons["data.backup"].tap()
        // Files remembers its last folder across runs. Always choose the same
        // local root for export and import, including on a reused simulator.
        let localExport = app.cells.matching(NSPredicate(format: "label CONTAINS %@", "On My iPhone")).firstMatch
        for _ in 0..<10 {
            if localExport.waitForExistence(timeout: 1) { localExport.tap(); break }
            let back = app.buttons["BackButton"].firstMatch
            if back.waitForExistence(timeout: 1) { back.tap() } else { break }
        }
        let name = "SplitSlipTest-" + UUID().uuidString.prefix(8)
        let identifiedFilename = app.textFields["DOCPicker.filenameTextField"]
        let filename = identifiedFilename.waitForExistence(timeout: 3) ? identifiedFilename : app.textFields.firstMatch
        XCTAssertTrue(filename.waitForExistence(timeout: 10), app.debugDescription)
        filename.tap(withNumberOfTaps: 3, numberOfTouches: 1)
        filename.typeText(String(name))
        let save = app.buttons["Save"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 5)); save.tap()
        let message = app.staticTexts["data.message"]
        XCTAssertTrue(message.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(message.label.contains("Backup saved"), message.label)
        let delete = app.buttons["data.deleteAll"]
        XCTAssertTrue(reveal(delete)); delete.tap()
        app.alerts.buttons["Delete all local data"].tap()
        XCTAssertTrue(message.label.contains("deleted"), message.label)
        let restore = app.buttons["data.restore"]
        XCTAssertTrue(reveal(restore)); restore.tap()
        let browse = app.tabBars.buttons["Browse"].firstMatch
        if browse.waitForExistence(timeout: 3) { browse.tap() }
        let local = app.cells.matching(NSPredicate(format: "label CONTAINS %@", "On My iPhone")).firstMatch
        if local.waitForExistence(timeout: 3) { local.tap() }
        let folder = app.cells.matching(NSPredicate(format: "label CONTAINS %@", String(name))).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 10), app.debugDescription)
        folder.tap()
        let open = app.buttons["Open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5), app.debugDescription); open.tap()
        let replace = app.alerts.buttons["Replace library"]
        XCTAssertTrue(replace.waitForExistence(timeout: 10), app.debugDescription); replace.tap()
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        XCTAssertTrue(message.label.contains("Backup restored"), message.label)
        app.buttons["Done"].tap()
        app.terminate(); app.launchArguments = ["-ui-testing"]; app.launch()
        XCTAssertTrue(app.buttons["home.draft.0"].waitForExistence(timeout: 10))
        app.buttons["home.draft.0"].tap()
        containerExists("editor.root")
        XCTAssertTrue(reveal(app.buttons["editor.reference.remove"]), "Restored receipt must retain its photo")
    }

    func testDataDeletionRequiresConfirmationAndPersists() throws {
        app.launchArguments = ["-ui-testing", "-reset-store", "-seed-workspace", "DDAAAAAA-0000-0000-0000-000000000001"]
        app.launch()
        XCTAssertTrue(app.buttons["home.draft.0"].waitForExistence(timeout: 10))
        app.buttons["home.data"].tap()
        let delete = app.buttons["data.deleteAll"]
        XCTAssertTrue(reveal(delete)); delete.tap()
        app.alerts.buttons["Keep my data"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["home.draft.0"].waitForExistence(timeout: 5))
        app.buttons["home.data"].tap()
        XCTAssertTrue(reveal(delete)); delete.tap()
        app.alerts.buttons["Delete all local data"].tap()
        XCTAssertTrue(app.staticTexts["data.message"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["data.message"].label.contains("deleted"), app.staticTexts["data.message"].label)
        app.buttons["Done"].tap()
        app.terminate()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        XCTAssertFalse(app.buttons["home.draft.0"].exists)
        containerExists("home.empty")
    }

    func testValidationErrorsAreVisibleAndDestructiveRemovalConfirms() throws {
        freshLaunch()
        app.buttons["home.newReceipt"].tap()
        containerExists("editor.root", timeout: 10)
        openTab("Receipt")

        // Bad amount is refused visibly and does not corrupt the draft.
        tapAndType(app.textFields["editor.expectedTotal"], text: "1,000.00")
        XCTAssertTrue(revealText("Amounts cannot use separators like commas (write 1000.00, not 1,000.00)."))

        // Add a person, then a line, split it, and removal must confirm first.
        openTab("People")
        tapAndType(app.textFields["editor.participantName"], text: "Ana")
        app.buttons["editor.addParticipant"].tap()
        openTab("Receipt")
        app.buttons["editor.addLine"].tap()
        tapAndType(app.textFields["editor.line.0.label"], text: "Food")
        tapAndType(app.textFields["editor.line.0.amount"], text: "5.00")
        let selector = app.switches["editor.line.0.person.Ana"]
        XCTAssertTrue(reveal(selector))
        let originalX = selector.frame.midX
        selector.tap()
        XCTAssertEqual(selector.frame.midX, originalX, accuracy: 1)
        XCTAssertLessThan(app.textFields["editor.line.0.weight.Ana"].frame.maxX, selector.frame.minX)

        openTab("People")
        let remove = app.buttons["editor.removeParticipant.Ana"]
        XCTAssertTrue(reveal(remove), "remove-participant button never became hittable")
        remove.tap()
        let alert = app.alerts["Remove participant?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Destructive removal must confirm")
        XCTAssertTrue(alert.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", "will need new recipients"))
            .firstMatch.exists)
        alert.buttons["Remove Ana"].tap()

        // The row is flagged needing review — never silently reassigned.
        openTab("Receipt")
        XCTAssertTrue(revealText("Needs review after a participant was removed"))
    }

    /// Issue #4: the reference viewport and workspace selection are restored
    /// across tab switches, a simulated rotation and a full relaunch —
    /// state lives in the workspace model, not the view. The system photo
    /// picker is driven by the user only; this journey verifies everything
    /// downstream of an accepted import using a deterministic seeded draft.
    func testReferenceViewportAndSelectionSurviveNavigationRotationAndRelaunch() throws {
        let seededID = "00000000-0000-0000-0000-00000000E4D4"
        app.launchArguments = ["-ui-testing", "-reset-store", "-seed-workspace", seededID]
        app.launch()
        containerExists("home.root")
        XCTAssertTrue(app.buttons["home.draft.0"].waitForExistence(timeout: 10))
        app.buttons["home.draft.0"].tap()
        containerExists("editor.root", timeout: 10)
        openTab("Receipt")

        // Seeded reference import is active: the viewport's zoom label
        // exists (the photo itself is deliberately accessibilityHidden —
        // any AX element over scaled content reports overflowing frames
        // that poison sibling hittability; the labeled control rows are
        // the accessible surface, proven hittable below). Existence-based:
        // static text never accepts touches.
        XCTAssertTrue(revealExists(app.descendants(matching: .any)["editor.reference.zoomLabel"]),
                      "reference viewport missing")

        // Viewport state starts at the seeded 2.0× and buttons drive it.
        XCTAssertTrue(revealText("2.0×"), "seeded zoom label missing")
        let zoomIn = app.buttons["editor.reference.zoomIn"]
        XCTAssertTrue(reveal(zoomIn), referenceSubtreeDump("zoom-in never hittable"))
        zoomIn.tap()
        XCTAssertTrue(revealText("2.5×"), "zoom-in button must change persisted zoom")

        // Pan supplement buttons (explicit control; gestures optional).
        let panRight = app.buttons["editor.reference.pan.arrow.right"]
        XCTAssertTrue(reveal(panRight))
        panRight.tap()

        // Select the line so its selection must also survive.
        let selectLine = app.buttons["editor.line.0.select"]
        XCTAssertTrue(reveal(selectLine))
        selectLine.tap()
        XCTAssertTrue(revealText("Line: Food"))

        // Tab switch away and back: viewport unchanged (no reset).
        openTab("People")
        openTab("Receipt")
        XCTAssertTrue(revealText("2.5×"), "zoom must survive tab switch")

        // Simulated device rotation: layout changes, state must not.
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(revealText("2.5×"), "zoom must survive rotation")
        XCTAssertTrue(revealText("Line: Food"))
        XCUIDevice.shared.orientation = .portrait

        // Full relaunch (no reset): selection + viewport restored from disk.
        app.terminate()
        app.launchArguments = ["-ui-testing", "-seed-workspace", seededID]
        app.launch()
        containerExists("home.root")
        app.buttons["home.draft.0"].tap()
        containerExists("editor.root", timeout: 10)
        // Selection restore includes the tab (Receipt) and viewport.
        XCTAssertTrue(revealText("2.5×"), "zoom must survive relaunch")
        XCTAssertTrue(revealText("Line: Food"), "selected line must survive relaunch")

        // Removing the reference is explicit and leaves the rest intact.
        let removeReference = app.buttons["editor.reference.remove"]
        XCTAssertTrue(reveal(removeReference))
        removeReference.tap()
        XCTAssertTrue(reveal(app.buttons["editor.reference.pick"]),
                      "removing the reference must restore the picker entry")
        XCTAssertTrue(revealText("Line: Food"), "removing the image must not clear the selection")
    }
}
