import XCTest

final class ScanProgressTests: XCTestCase {
    func testFolderPickerCanBeCancelledWithoutSourceMutation() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-fresh-catalog", "--uitest-synthetic-detector"]
        app.launch()
        let choose = app.buttons["choose-folder"]
        XCTAssertTrue(choose.waitForExistence(timeout: 10)); XCTAssertTrue(choose.isEnabled)
        choose.tap()
        let cancel = app.buttons["Cancel"].firstMatch
        let ready = NSPredicate { _, _ in cancel.exists && cancel.isHittable }
        let presentation = XCTNSPredicateExpectation(predicate: ready, object: cancel)
        XCTAssertEqual(XCTWaiter.wait(for: [presentation], timeout: 15), .completed)
        XCTAssertTrue(cancel.isHittable)
        cancel.tap()
        XCTAssertTrue(app.staticTexts["No folder selected"].exists)
        XCTAssertFalse(app.buttons["start-scan"].exists)
    }
    func testInitialScanPreviewsBeforeCompletionAndCancellation() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-synthetic-source", "--uitest-hold-after-first", "--uitest-synthetic-detector"]
        app.launch()
        XCTAssertTrue(app.buttons["choose-folder"].waitForExistence(timeout: 10))
        app.buttons["choose-folder"].tap()
        XCTAssertTrue(app.buttons["start-scan"].waitForExistence(timeout: 5))
        app.buttons["start-scan"].tap()
        app.alerts.buttons["Start scan"].tap()
        let preview = app.images["Photo preview"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["cancel-scan"].exists)
        XCTAssertTrue(app.staticTexts["Total unknown until discovery completes"].exists)
        app.buttons["cancel-scan"].tap()
        let phase = app.staticTexts["scan-phase"]
        let cancelled = NSPredicate(format: "label == 'Cancelled'")
        expectation(for: cancelled, evaluatedWith: phase)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(preview.exists)
        XCTAssertTrue(app.buttons["start-scan"].exists)
        XCTAssertTrue(app.staticTexts["Scan cancelled. Accepted photos remain; resume to check the source."].exists)
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
        expectation(for: NSPredicate(format: "label == 'Cancelled'"), evaluatedWith: phase)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(preview.exists)
        app.buttons["start-scan"].tap(); app.alerts.buttons["Start scan"].tap()
        XCTAssertTrue(preview.exists)
        expectation(for: NSPredicate(format: "label == 'Completed'"), evaluatedWith: phase)
        waitForExpectations(timeout: 15)
        XCTAssertTrue(app.staticTexts["Discovered 3 · Processed 3 · Skipped 0 · Failed 0"].exists)
        XCTAssertTrue(app.staticTexts["Discovery complete"].exists)
    }

}
