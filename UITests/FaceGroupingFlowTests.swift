import XCTest

/// Fictional saved-analysis journey; owner matching accuracy is a separate qualification.
final class FaceGroupingFlowTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false; applyRequestedOrientation() }
    func testGroupNameReopenAndSearchJourney() {
        let app = launchFixture()
        navigateTo("Library", app); scanFixture(app)
        navigateTo("People", app)
        let group = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'face-group-' AND label CONTAINS '3 faces'")).firstMatch
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
        let photoButtons = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'group-photo-'"))
        let memberIDs = Set(photoButtons.allElementsBoundByIndex.map(\.identifier))
        let openPhoto = photoButtons.firstMatch
        XCTAssertTrue(openPhoto.waitForExistence(timeout: 10)); revealElement(openPhoto, app); openPhoto.tap()
        let viewerStatus = app.staticTexts["viewer-status"]
        XCTAssertTrue(waitUntilTrue { viewerStatus.label == "Original" })
        XCTAssertTrue(app.images["viewer-image"].exists)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", viewerStatus.label)).count, 1)
        attachScreenshot("named-group-matching-photo-original", app)
        app.buttons["close-viewer"].tap()
        XCTAssertTrue(heading.waitForExistence(timeout: 10)); XCTAssertEqual(heading.label, "Fictional Ada")
        XCTAssertEqual(before.label, count)
        XCTAssertEqual(Set(photoButtons.allElementsBoundByIndex.map(\.identifier)), memberIDs)
        attachScreenshot("named-group-after-photo-close", app)
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
        let possible = app.staticTexts["search-possible-count"]
        XCTAssertTrue(possible.waitForExistence(timeout: 10)); XCTAssertEqual(possible.label, "2 possible photos")
        let review = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'search-review-group-'")).firstMatch
        revealElement(review, app); review.tap()
        let confirm = app.buttons["reviewed-group-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10)); revealElement(confirm, app); confirm.tap()
        let action = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Confirm 3 faces as Fictional Ada'")).firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 10)); action.tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 10))
        // Search owns this group destination locally; use its real back action to pop it.
        let backToSearch = app.navigationBars.buttons["Search"].firstMatch
        XCTAssertTrue(backToSearch.waitForExistence(timeout: 10)); backToSearch.tap()
        XCTAssertTrue(app.scrollViews["screen-Search"].waitForExistence(timeout: 10))
        let confirmedCount = app.staticTexts["search-result-count"]
        XCTAssertTrue(waitUntilTrue { confirmedCount.label == "3 confirmed photos" })
        navigateTo("People", app)
        let undo = app.buttons["decision-undo"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 10)); undo.tap()
        // Returning preserves filters and captures the metadata decision automatically.
        navigateTo("Search", app)
        XCTAssertTrue(waitUntilTrue { possible.label == "2 possible photos" })
    }
}
