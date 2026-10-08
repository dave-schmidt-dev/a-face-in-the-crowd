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
        let assigned = app.staticTexts["person-confirmed-count"]
        XCTAssertTrue(assigned.waitForExistence(timeout: 10)); XCTAssertEqual(assigned.label, "3 confirmed photos")
        XCTAssertTrue(app.staticTexts["person-photos-start"].exists)
        XCTAssertFalse(app.buttons["possible-confirm"].exists)
        XCTAssertFalse(app.buttons["possible-reject"].exists)
        XCTAssertFalse(app.buttons["reviewed-group-confirm"].exists)
        navigateTo("Verify", app)
        XCTAssertTrue(app.staticTexts["verify-review-heading"].waitForExistence(timeout: 10))
        navigateTo("Search", app)
        let chip = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'search-person-' AND label CONTAINS 'Fictional Ada'")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10)); chip.tap()
        app.buttons["search-mode-any"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'search-photo-'" )).firstMatch.waitForExistence(timeout: 15))
        let confirmedCount = app.staticTexts["search-result-count"]
        XCTAssertTrue(waitUntilTrue { confirmedCount.label == "3 confirmed photos" })
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'search-review-group-'" )).count, 0)
        navigateTo("People", app)
        let undo = app.buttons["decision-undo"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 10)); undo.tap()
        let unnamed = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'face-group-' AND label CONTAINS '3 faces'" )).firstMatch
        XCTAssertTrue(unnamed.waitForExistence(timeout: 10), "Undo must restore the entire group to unnamed state")
    }

    func testNamedPartialGroupRepairAppliesWholeGroupAndUndo() {
        let app = launchFixture(.compactXXXL)
        navigateTo("Library", app); scanFixture(app)
        navigateTo("People", app)
        let face = app.buttons.matching(NSPredicate(format: "identifier == 'unidentified-face' AND label CONTAINS 'nested/synthetic-0.jpg'" )).firstMatch
        revealElement(face, app)
        XCTAssertTrue(face.waitForExistence(timeout: 10)); XCTAssertTrue(isRevealed(face, app)); face.tap()
        let name = app.textFields["new-person-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10)); name.tap(); name.typeText("Susie")
        let save = app.buttons["save-selected-face"]; revealElement(save, app); save.tap()
        XCTAssertTrue(name.waitForNonExistence(timeout: 10))
        let person = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'person-' AND label CONTAINS 'Susie'" )).firstMatch
        XCTAssertTrue(person.waitForExistence(timeout: 10)); revealElement(person, app); person.tap()
        let repair = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'repair-partial-group-'" )).firstMatch
        XCTAssertTrue(repair.waitForExistence(timeout: 10), "The earlier one-face label must expose one group-scale repair")
        revealElement(repair, app); XCTAssertTrue(isRevealed(repair, app))
        XCTAssertGreaterThanOrEqual(repair.frame.height, 44)
        attachScreenshot("partial-group-repair-person", app)
        let groupSize = Int(repair.label.components(separatedBy: "·").last?.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "") ?? 0
        XCTAssertGreaterThan(groupSize, 1, "Repair must represent the whole multi-face group")
        repair.tap()
        let count = app.staticTexts["person-confirmed-count"]
        let expectedCount = "\(groupSize) confirmed photo\(groupSize == 1 ? "" : "s")"
        XCTAssertTrue(waitUntilTrue { count.label == expectedCount }, "Applying the group name must label every group member")
        let undo = app.buttons["decision-undo"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 10)); undo.tap()
        XCTAssertTrue(waitUntilTrue { count.label == "1 confirmed photo" }, "Undo restores the prior single-face assignment")
        XCTAssertTrue(repair.waitForExistence(timeout: 10), "Undo restores the repair action")
    }
}
