import Foundation
import XCTest

/// Issue #3 acceptance journey: create → allocate → mismatch → correct →
/// finalize → relaunch → inspect → duplicate. Button/tap based only for the
/// app itself (no drag-only interactions); the tests may *scroll* the list,
/// which SwiftUI `List` virtualizes when the keyboard changes the offset.
/// Every launch resets the on-disk store with `-reset-store` except the
/// explicit relaunch step, which proves the finalized snapshot survives
/// termination.
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

    private func pollHittable(_ element: XCUIElement, seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if (try? element.isHittable) == true { return true }
            usleep(250_000)
        }
        return false
    }

    /// Tap, type, then commit deterministically: while any editor field has
    /// focus a keyboard toolbar "Done" button exists; tapping it clears focus
    /// (hiding the keyboard) before the next interaction.
    private func tapAndType(_ element: XCUIElement, text: String) {
        XCTAssertTrue(reveal(element), "element \(element.identifier) never became hittable")
        element.tap()
        element.typeText(text)
        let done = app.buttons["editor.dismissKeyboard"]
        if done.waitForExistence(timeout: 3) {
            done.tap()
        }
    }

    private func freshLaunch() {
        app.launchArguments = ["-ui-testing", "-reset-store"]
        app.launch()
        containerExists("home.root")
        XCTAssertTrue(revealText("No receipts yet. Create one to get started."))
    }

    /// Enter currency stays USD; add two people, one line, and reach a
    /// deliberate total mismatch (rows 30.00 vs printed 20.00).
    private func buildMismatchedReceipt() {
        app.buttons["home.newReceipt"].tap()
        containerExists("editor.root", timeout: 10)

        tapAndType(app.textFields["editor.expectedTotal"], text: "20.00")
        tapAndType(app.textFields["editor.participantName"], text: "Ana")
        app.buttons["editor.addParticipant"].tap()
        tapAndType(app.textFields["editor.participantName"], text: "Bo")
        app.buttons["editor.addParticipant"].tap()

        app.buttons["editor.addLine"].tap()
        tapAndType(app.textFields["editor.line.0.label"], text: "Appetizer")
        tapAndType(app.textFields["editor.line.0.amount"], text: "30.00")

        // Split equally across both people.
        let split = app.buttons["editor.line.0.splitEqually"]
        XCTAssertTrue(reveal(split), "split-equally button never became hittable")
        split.tap()

        // Mismatch must be visible: rows exceed the printed total by 10.00.
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
        let done = app.buttons["editor.dismissKeyboard"]
        if done.waitForExistence(timeout: 3) { done.tap() }
        XCTAssertTrue(revealText("Rows match the entered total"))
        XCTAssertTrue(app.buttons["editor.finalize"].isEnabled)

        app.buttons["editor.finalize"].tap()

        // Back on home, the finalized receipt is listed.
        XCTAssertTrue(app.staticTexts["Finalized"].waitForExistence(timeout: 5))
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

        // Duplicate-to-correct forks a new linked draft.
        app.buttons["snapshot.duplicate"].tap()
        containerExists("editor.root", timeout: 5)
        XCTAssertTrue(app.navigationBars["Correction draft"].exists)

        // Canceling the correction must keep the snapshot (no data loss).
        app.buttons["editor.cancelCorrection"].tap()
        let alert = app.alerts["Cancel this correction?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Cancel correction"].tap()
        containerExists("home.root", timeout: 5)
        XCTAssertTrue(app.buttons["home.snapshot.0"].waitForExistence(timeout: 5))
    }

    func testValidationErrorsAreVisibleAndDestructiveRemovalConfirms() throws {
        freshLaunch()
        app.buttons["home.newReceipt"].tap()
        containerExists("editor.root", timeout: 10)

        // Bad amount is refused visibly and does not corrupt the draft.
        tapAndType(app.textFields["editor.expectedTotal"], text: "1,000.00")
        XCTAssertTrue(revealText("Amounts cannot use separators like commas (write 1000.00, not 1,000.00)."))

        // Add a person, then a line, split it, and removal must confirm first.
        tapAndType(app.textFields["editor.participantName"], text: "Ana")
        app.buttons["editor.addParticipant"].tap()
        app.buttons["editor.addLine"].tap()
        tapAndType(app.textFields["editor.line.0.label"], text: "Food")
        tapAndType(app.textFields["editor.line.0.amount"], text: "5.00")
        let split = app.buttons["editor.line.0.splitEqually"]
        XCTAssertTrue(reveal(split))
        split.tap()

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
        XCTAssertTrue(revealText("Needs review after a participant was removed"))
    }
}
