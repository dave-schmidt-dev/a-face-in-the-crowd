import XCTest

final class AccessibilityFlowTests: XCTestCase {
    func testCompactLargeTextSearchLabelsAndControlSizes() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-synthetic-source", "--uitest-compact", "--uitest-catalog-token", UUID().uuidString,
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let search = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ OR label == %@", "navigate-Search", "Search")).firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5)); XCTAssertTrue(search.isHittable); search.tap()
        let screen = app.scrollViews["screen-Search"]; XCTAssertTrue(screen.waitForExistence(timeout: 5))
        for id in ["search-mode-together", "search-mode-any", "search-mode-only"] {
            let control = app.buttons[id]
            for _ in 0..<8 { if control.exists && control.isHittable { break }; screen.swipeUp() }
            XCTAssertTrue(control.exists); XCTAssertTrue(control.isHittable)
            XCTAssertGreaterThanOrEqual(control.frame.height, 44); control.tap()
        }
        let show = app.buttons["show-photos"]
        for _ in 0..<8 { if show.exists && show.isHittable { break }; screen.swipeUp() }
        XCTAssertTrue(show.exists); XCTAssertFalse(show.isEnabled)
        XCTAssertTrue(app.staticTexts["query-sentence"].exists)
        XCTAssertTrue(app.staticTexts["possible-unavailable"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Synthetic compact XXXL search semantic controls"; attachment.lifetime = .keepAlways; add(attachment)
        // This case checks rendered labels and target sizes; it does not operate VoiceOver or a hardware keyboard.
        XCTAssertEqual(app.buttons["search-mode-only"].label, "Only selected")
    }
}
