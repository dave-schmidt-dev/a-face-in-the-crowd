import XCTest

/// Design-pass UI contract, second half: one status per screen, Settings order, Library to viewer,
/// Search layout, Verify copy and details, section path persistence, pull-to-refresh and a
/// screenshot walk. Fictional synthetic fixture only.
final class DesignScreensTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false; applyRequestedOrientation() }

    private func setSuggestions(_ on: Bool, _ app: XCUIApplication) {
        navigateTo("Verify", app)
        let toggle = app.switches["evaluation-suggestions-toggle"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10)); revealElement(toggle, app)
        let wanted = on ? "1" : "0"
        if toggle.value as? String != wanted {
            let inner = toggle.switches.firstMatch
            if inner.exists { inner.tap() } else { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap() }
        }
        XCTAssertTrue(waitUntilTrue { toggle.value as? String == wanted }, "suggestions toggle did not turn \(wanted)")
    }

    // MARK: Screenshot walk

    func testScreenshotWalk() {
        let app = launchFixture(extra: ["--uitest-synthetic-suggestions"])
        attachScreenshot("shot-welcome", app)
        setSuggestions(true, app)
        navigateTo("Library", app); scanFixture(app)
        attachScreenshot("shot-library", app)
        nameFace("Fixture A", app); nameFace("Fixture B", app)
        navigateTo("People", app); attachScreenshot("shot-people", app)
        openFirstPerson(app); attachScreenshot("shot-person-detail", app)
        navigateTo("Verify", app)
        _ = app.descendants(matching: .any)["review-card"].firstMatch.waitForExistence(timeout: 20)
        attachScreenshot("shot-verify", app)
        navigateTo("Search", app)
        let chip = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'search-person-'")).firstMatch
        if chip.waitForExistence(timeout: 10) { chip.tap(); app.buttons["search-mode-any"].tap() }
        _ = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'search-photo-'")).firstMatch.waitForExistence(timeout: 15)
        attachScreenshot("shot-search", app)
        tapToolbar("settings", app)
        _ = app.buttons["delete-local-catalog"].waitForExistence(timeout: 10)
        attachScreenshot("shot-settings", app)
    }
}
