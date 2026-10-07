import XCTest

final class ScanProgressTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false; applyRequestedOrientation() }
    func testFolderPickerCanBeCancelledWithoutSourceMutation() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-fresh-catalog", "--uitest-synthetic-detector"]
        app.launch()
        let choose = app.buttons["choose-folder"]
        XCTAssertTrue(choose.waitForExistence(timeout: 10)); XCTAssertTrue(choose.isEnabled)
        choose.tap()
        let cancel = app.buttons["Cancel"].firstMatch
        let ready = NSPredicate { _, _ in self.isHittableSafely(cancel, app) }
        let presentation = XCTNSPredicateExpectation(predicate: ready, object: cancel)
        XCTAssertEqual(XCTWaiter.wait(for: [presentation], timeout: 15), .completed)
        XCTAssertTrue(isHittableSafely(cancel, app))
        cancel.tap()
        XCTAssertTrue(app.buttons["choose-folder"].exists)
        XCTAssertFalse(app.staticTexts["No folder selected"].exists)
        XCTAssertFalse(app.buttons["start-scan"].exists)
    }
    func testCancelledScanCanResumeWithCachedPreviewsAndTruthfulCounts() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-synthetic-source", "--uitest-hold-after-first", "--uitest-synthetic-detector"]
        app.launch()
        XCTAssertTrue(app.buttons["choose-folder"].waitForExistence(timeout: 10))
        app.buttons["choose-folder"].tap()
        XCTAssertTrue(app.buttons["start-scan"].waitForExistence(timeout: 5))
        app.buttons["start-scan"].tap(); app.alerts.buttons["Start scan"].tap()
        let preview = app.images["Photo preview"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        app.buttons["cancel-scan"].tap()
        let phase = app.staticTexts["scan-phase"]
        expectation(for: NSPredicate(format: "value == 'cancelled'"), evaluatedWith: phase)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(preview.exists)
        app.buttons["start-scan"].tap(); app.alerts.buttons["Start scan"].tap()
        XCTAssertTrue(preview.exists)
        expectation(for: NSPredicate(format: "value == 'completed'"), evaluatedWith: phase)
        waitForExpectations(timeout: 15)
        XCTAssertTrue(app.staticTexts["scan-counts"].exists)
        XCTAssertTrue(app.staticTexts["Discovered 3 · Processed 3 · Skipped 0 · Failed 0"].exists)
        XCTAssertFalse(app.staticTexts["Discovery complete"].exists)
    }

}
