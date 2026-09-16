import XCTest

final class SplitSlipLaunchTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testBootstrapHomeLaunches() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()

        XCTAssertTrue(app.otherElements["bootstrap.home"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Split Slip"].exists)
        XCTAssertTrue(app.staticTexts["Receipt entry and allocation tools arrive in the next milestones."].exists)
    }
}
