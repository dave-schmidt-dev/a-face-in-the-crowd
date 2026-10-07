import XCTest

/// Fictional saved-analysis journey; owner matching accuracy is a separate qualification.
final class FaceGroupingFlowTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false; applyRequestedOrientation() }
    func testGroupNameReopenAndSearchJourney() {
        let app = launchFixture()
        navigateTo("Library", app); scanFixture(app)
        navigateTo("People", app)
        let group = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'face-group-'")).firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 15)); revealElement(group, app); group.tap()
        let before = app.staticTexts["face-group-member-count"].firstMatch
        XCTAssertTrue(before.waitForExistence(timeout: 10))
        let count = before.label
        let field = app.textFields["group-name-field"]
        revealElement(field, app); XCTAssertTrue(field.exists); field.tap(); field.typeText("Fictional Ada")
        let save = app.buttons["save-group-name"]; revealElement(save, app); save.tap()
        let heading = app.staticTexts["face-group-named-heading"]
        XCTAssertTrue(heading.waitForExistence(timeout: 10)); XCTAssertEqual(heading.label, "Fictional Ada")
        XCTAssertEqual(before.label, count, "Naming retains the inspected group's photos")
        app.terminate(); app.launch()
        navigateTo("People", app)
        let person = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'person-' AND label CONTAINS 'Fictional Ada'")).firstMatch
        XCTAssertTrue(person.waitForExistence(timeout: 15)); revealElement(person, app); person.tap()
        XCTAssertTrue(app.staticTexts["person-name-heading"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["possible-photos-start"].waitForExistence(timeout: 10))
        navigateTo("Search", app)
        let chip = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'search-person-' AND label CONTAINS 'Fictional Ada'")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10)); chip.tap()
        app.buttons["search-mode-any"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'search-photo-'")).firstMatch.waitForExistence(timeout: 15))
    }
}
