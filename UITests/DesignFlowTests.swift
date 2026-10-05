import XCTest

/// Design-pass UI contract over the fictional synthetic fixture: layout fit at every width and
/// text size, one status per screen, human status copy, Settings order and the CLEAR fixes.
final class DesignFlowTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false; applyRequestedOrientation() }

    // MARK: Helpers

    /// Elements must lie inside the window. A frame that overflows is how clipped text shows up.
    private func assertFits(_ ids: [String], _ app: XCUIApplication, _ context: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        let window = app.windows.firstMatch.frame
        for id in ids {
            let element = app.descendants(matching: .any)[id].firstMatch
            XCTAssertTrue(element.waitForExistence(timeout: 10), "\(context): \(id) missing", file: file, line: line)
            revealElement(element, app)   // the horizontal fit is judged where the element is actually on screen
            let frame = element.frame
            XCTAssertGreaterThan(frame.width, 0, "\(context): \(id) has no width", file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.minX, window.minX - 1, "\(context): \(id) starts left of the window \(frame) in \(window)", file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxX, window.maxX + 1, "\(context): \(id) runs past the window \(frame) in \(window)", file: file, line: line)
        }
    }

    /// Waits until an element's frame stops changing, so a mid-transition frame is never judged.
    private func settle(_ element: XCUIElement) {
        var previous = element.frame
        _ = waitUntilTrue(8) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            defer { previous = element.frame }
            return element.frame == previous
        }
    }

    private func personDetailFits(_ layout: Layout, _ label: String) {
        let app = launchFixture(layout)
        scanFixture(app); nameFace("Fixture A", app); openFirstPerson(app)
        settle(app.staticTexts["person-confirmed-count"])
        assertFits(["person-name-heading", "person-confirmed-count", "rename-person-name", "save-person-name"], app, label)
        XCTAssertEqual(app.staticTexts["person-name-heading"].label, "Fixture A")
        attachScreenshot("person-detail-" + label, app)
    }

    // MARK: Tests

    /// Names the first unidentified face.
    private func nameAnother(_ value: String, _ app: XCUIApplication) {
        navigateTo("People", app)
        let face = app.buttons["unidentified-face"].firstMatch
        revealElement(face, app); XCTAssertTrue(face.waitForExistence(timeout: 10)); face.tap()
        let field = app.textFields["new-person-name"]; XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap(); field.typeText(value)
        tapButton("save-selected-face", app); XCTAssertTrue(field.waitForNonExistence(timeout: 10))
    }

    private func recordedPeople(_ app: XCUIApplication) -> Int {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'person-' AND label CONTAINS[c] 'record '")).count
    }

    func testPersonDetailFitsRegularWidth() { personDetailFits(.regular, "regular") }

    /// C8: a record suffix appears only to tell apart people who share a name.
    func testRecordSuffixOnlyWhereNamesAreIdentical() {
        let app = launchFixture()
        scanFixture(app); nameFace("Twin", app)
        navigateTo("People", app)
        XCTAssertEqual(recordedPeople(app), 0, "a unique name needs no record text")
        openFirstPerson(app)
        XCTAssertFalse(app.staticTexts["person-record"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Possible matching'")).firstMatch.exists)
        nameAnother("Twin", app)
        navigateTo("People", app)
        XCTAssertTrue(waitUntilTrue { recordedPeople(app) == 2 }, "both identical names show their record")
        openFirstPerson(app)
        XCTAssertTrue(app.staticTexts["person-record"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["person-record"].label.hasPrefix("Record "))
    }

    /// C10 and C11: at the largest text size Save stays pinned above the keyboard and is disabled
    /// until the name is valid; Unsure stays reachable.
    func testNamingSheetAtLargestTextPinsSaveAndValidatesName() {
        let app = launchFixture(.compactXXXL)
        scanFixture(app); navigateTo("People", app)
        let face = app.buttons["unidentified-face"].firstMatch
        revealElement(face, app); XCTAssertTrue(face.waitForExistence(timeout: 10)); face.tap()
        let field = app.textFields["new-person-name"]; XCTAssertTrue(field.waitForExistence(timeout: 10))
        let save = app.buttons["save-selected-face"]
        XCTAssertTrue(save.waitForExistence(timeout: 5)); XCTAssertFalse(save.isEnabled, "empty name")
        XCTAssertEqual(app.staticTexts["name-hint"].label, "Enter a name to save this face.")
        field.tap(); field.typeText("   ")
        XCTAssertFalse(save.isEnabled, "blank name")
        clearAndType(field, "Pat", app)
        XCTAssertTrue(waitUntilTrue { save.isEnabled }, "valid name enables Save")
        XCTAssertFalse(app.staticTexts["name-hint"].exists)
        XCTAssertTrue(isHittableSafely(save, app), "Save stays reachable with the keyboard up")
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists { XCTAssertLessThanOrEqual(save.frame.maxY, keyboard.frame.minY + 1, "Save sits above the keyboard") }
        attachScreenshot("naming-sheet-XXXL-keyboard", app)
        field.typeText(String(repeating: "x", count: 121))
        XCTAssertFalse(save.isEnabled, "over-long name"); XCTAssertEqual(app.staticTexts["name-hint"].label, "Names can be up to 120 characters.")
        if app.keyboards.buttons["return"].exists { app.keyboards.buttons["return"].tap() }
        let unsure = app.buttons["defer-face"]; revealElement(unsure, app)
        XCTAssertTrue(isRevealed(unsure, app), "Unsure is reachable by scrolling")
    }

    func testPersonDetailFitsCompactWidth() { personDetailFits(.compact, "compact") }
    func testPersonDetailFitsCompactLargestText() { personDetailFits(.compactXXXL, "compact-XXXL") }

    /// A real save failure shows the warning and retry rows in the bottom inset. The pushed Person
    /// screen must honour that inset: Delete person, its last control, ends above every inset row
    /// and stays fully hittable at the end of the scroll. No test-only padding is involved.
    func testPersonDetailLastControlClearsBottomInset() {
        let app = launchFixture(extra: ["--uitest-presentation-controls", "--uitest-presentation-save-retry"])
        scanFixture(app); nameFace("Fixture A", app); openFirstPerson(app)
        tapButton("block-presentation-save", app)
        let field = app.textFields["rename-person-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap(); field.typeText(" draft")
        let retry = app.buttons["retry-presentation-save"].firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 15), "the real save-failure row is shown")
        let delete = app.buttons["delete-person"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 10)); revealElement(delete, app)
        XCTAssertTrue(isRevealed(delete, app), "Delete person " + whyNotRevealed(delete, app))
        let rows = ["presentation-save-status", "presentation-save-warning", "presentation-persistence-probe"]
            .map { app.staticTexts[$0].firstMatch }.filter { $0.exists } + [retry]
        for row in rows {
            XCTAssertLessThanOrEqual(delete.frame.maxY, row.frame.minY + 1, "Delete person \(delete.frame) sits under inset row \(row.identifier) \(row.frame)")
        }
        XCTAssertTrue(isHittableSafely(delete, app))
    }
}
