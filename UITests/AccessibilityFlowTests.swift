import XCTest

final class AccessibilityFlowTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false; applyRequestedOrientation() }
    func testCompactLargeTextSearchLabelsAndControlSizes() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-synthetic-source", "--uitest-compact", "--uitest-catalog-token", UUID().uuidString,
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let search = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ OR label == %@", "navigate-Search", "Search")).firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5)); XCTAssertTrue(isHittableSafely(search, app)); search.tap()
        let screen = app.scrollViews["screen-Search"]; XCTAssertTrue(screen.waitForExistence(timeout: 5))
        let show = app.buttons["show-photos"]
        XCTAssertTrue(show.waitForExistence(timeout: 5)); revealElement(show, app)
        XCTAssertTrue(isRevealed(show, app), whyNotRevealed(show, app))
        XCTAssertGreaterThanOrEqual(show.frame.height, 44)
        for id in ["search-mode-together", "search-mode-any", "search-mode-only"] {
            let control = app.buttons[id]
            XCTAssertTrue(control.waitForExistence(timeout: 5)); revealElement(control, app)
            XCTAssertTrue(isRevealed(control, app), id + " " + whyNotRevealed(control, app))
            XCTAssertGreaterThanOrEqual(control.frame.height, 44); control.tap()
        }
        XCTAssertFalse(app.buttons["show-photos"].exists)
        let sentence = app.staticTexts["query-sentence"]
        XCTAssertTrue(sentence.waitForExistence(timeout: 5))
        XCTAssertEqual(sentence.label, "Select at least one confirmed person for Only selected.")
        let boundary = app.staticTexts["search-membership-boundary"]
        XCTAssertTrue(boundary.waitForExistence(timeout: 5))
        XCTAssertEqual(boundary.label, "Only selected uses confirmed identities and withholds unresolved faces.")
        XCTAssertFalse(app.staticTexts["only-coverage"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Synthetic compact XXXL search semantic controls"; attachment.lifetime = .keepAlways; add(attachment)
        // This case checks rendered labels and target sizes; it does not operate VoiceOver or a hardware keyboard.
        XCTAssertEqual(app.buttons["search-mode-only"].label, "Only selected")
    }
}
