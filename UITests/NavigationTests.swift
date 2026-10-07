import XCTest

final class NavigationTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false; applyRequestedOrientation() }
    func testRegularNavigationAndFolderSelection() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-fresh-catalog"]
        app.launch()
        XCTAssertTrue(app.buttons["choose-folder"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["choose-folder"].isEnabled)
        for title in ["People", "Verify", "Search", "Library"] {
            let navigation = app.descendants(matching: .any)["navigate-\(title)"].firstMatch
            XCTAssertTrue(navigation.waitForExistence(timeout: 3))
            XCTAssertTrue(isHittableSafely(navigation, app))
            navigation.tap()
            let screen = app.scrollViews["screen-\(title)"]
            XCTAssertTrue(screen.waitForExistence(timeout: 3))
            XCTAssertTrue(screen.exists)
        }
        app.buttons["settings"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["choose-folder"].exists)
        XCTAssertFalse(app.staticTexts["No folder selected"].exists)
    }
}
