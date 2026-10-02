import XCTest

final class NavigationTests: XCTestCase {
    func testRegularNavigationAndFolderSelection() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-fresh-catalog"]
        app.launch()
        XCTAssertTrue(app.buttons["choose-folder"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["choose-folder"].isEnabled)
        for title in ["People", "Verify", "Search", "Library"] {
            let navigation = app.descendants(matching: .any)["navigate-\(title)"].firstMatch
            XCTAssertTrue(navigation.waitForExistence(timeout: 3))
            XCTAssertTrue(navigation.isHittable)
            navigation.tap()
            let screen = app.scrollViews["screen-\(title)"]
            XCTAssertTrue(screen.waitForExistence(timeout: 3))
            XCTAssertTrue(screen.isHittable)
        }
        app.buttons["settings"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["No folder selected"].exists)
    }

    func testCompactNavigation() {
        // Exercise the compact shell explicitly while keeping the synthetic catalog isolated.
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-compact", "--uitest-fresh-catalog"]
        app.launch()
        XCTAssertTrue(app.buttons["choose-folder"].waitForExistence(timeout: 10))
        for title in ["People", "Verify", "Search", "Library"] {
            // Floating tabs can expose Cell or Other rather than TabBar/Button.
            let tab = app.descendants(matching: .any).matching(NSPredicate(
                format: "identifier == %@ OR label == %@", "navigate-\(title)", title)).firstMatch
            XCTAssertTrue(tab.waitForExistence(timeout: 3))
            XCTAssertTrue(tab.isHittable)
            tab.tap()
            let screen = app.scrollViews["screen-\(title)"]
            XCTAssertTrue(screen.waitForExistence(timeout: 3))
            XCTAssertTrue(screen.isHittable)
        }
        XCTAssertTrue(app.buttons["choose-folder"].isEnabled)
        app.buttons["settings"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["No folder selected"].exists)
    }
}
