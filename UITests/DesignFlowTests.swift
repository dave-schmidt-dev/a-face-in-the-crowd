import XCTest

/// Design-pass UI contract over the fictional synthetic fixture: layout fit at every width and
/// text size, one status per screen, human status copy, Settings order and the CLEAR fixes.
final class DesignFlowTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false; applyRequestedOrientation() }

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
}
