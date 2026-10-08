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

    func testPeopleFinishesMissingAndFailedAnalysisInPlace() {
        let app = launchFixture(extra: ["--uitest-analysis-finish"])
        navigateTo("Library", app); scanFixture(app)
        navigateTo("People", app)

        let status = app.staticTexts["face-analysis-status"].firstMatch
        XCTAssertTrue(waitUntilTrue(15) {
            status.exists && status.label.contains("1 photo: analysis failed")
                && status.label.contains("1 photo needs face analysis")
        }, "People distinguishes one retryable failure and one missing status")
        let finish = app.buttons["finish-face-analysis"].firstMatch
        XCTAssertTrue(finish.waitForExistence(timeout: 10)); revealElement(finish, app)
        XCTAssertTrue(isRevealed(finish, app)); XCTAssertTrue(finish.isEnabled)
        attachScreenshot("face-analysis-finish-available", app)

        let settings = app.buttons["settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10)); revealElement(settings, app); settings.tap()
        let disconnect = app.buttons["disconnect-source"].firstMatch
        XCTAssertTrue(disconnect.waitForExistence(timeout: 10)); disconnect.tap()
        let privacyConfirmation = app.alerts["Confirm privacy action"]
        XCTAssertTrue(privacyConfirmation.waitForExistence(timeout: 10))
        privacyConfirmation.buttons["Continue"].tap()
        let sourceState = app.staticTexts["backup-source-state"]
        XCTAssertTrue(waitUntilTrue(20) { sourceState.label == "No source folder selected" })
        app.buttons["Done"].tap()
        navigateTo("People", app)
        XCTAssertTrue(waitUntilTrue(15) {
            status.exists && status.label.contains("1 photo: analysis failed")
                && status.label.contains("1 photo needs face analysis")
        }, "Disconnecting the source must retain the saved analysis worklist")
        XCTAssertTrue(finish.waitForExistence(timeout: 10), "People keeps the completion action after source disconnect")
        revealElement(finish, app)
        attachScreenshot("face-analysis-finish-source-disconnected", app)

        finish.tap()
        XCTAssertTrue(app.alerts["Scan this folder?"].buttons["Start scan"].waitForExistence(timeout: 10),
                      "People selects the source and asks before scanning")
        app.alerts["Scan this folder?"].buttons["Start scan"].tap()
        let reconnect = app.alerts["Confirm the original source"]
        XCTAssertTrue(reconnect.waitForExistence(timeout: 10), "The source identity guard requires explicit confirmation")
        reconnect.buttons["Cancel"].tap()
        navigateTo("Search", app)
        navigateTo("People", app)
        XCTAssertFalse(reconnect.exists, "Cancel clears the pending source-confirmation request")
        XCTAssertTrue(finish.waitForExistence(timeout: 10), "Missing analysis remains available after cancelling source confirmation")
        revealElement(finish, app)
        finish.tap()
        XCTAssertTrue(reconnect.waitForExistence(timeout: 10), "A new explicit scan can request source confirmation again")
        reconnect.buttons["This is the original folder"].tap()
        let scanActivity = app.staticTexts["scan-message"].firstMatch
        XCTAssertTrue(scanActivity.waitForExistence(timeout: 10), "Finish starts the ordinary cached scan")
        let phase = app.staticTexts["scan-phase"].firstMatch
        XCTAssertTrue(waitUntilTrue(30) { phase.value as? String == "completed" })
        XCTAssertTrue(app.scrollViews["screen-People"].exists, "Completion stays on People")
        XCTAssertTrue(status.waitForNonExistence(timeout: 10), "Completed analysis clears the status")
        XCTAssertFalse(app.buttons["finish-face-analysis"].exists)
        attachScreenshot("face-analysis-finish-complete", app)
    }
}
