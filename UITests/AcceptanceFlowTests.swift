import XCTest

/// Synthetic causal flows. Authored and compiled here; native execution is a coordinated later gate.
final class AcceptanceFlowTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false; applyRequestedOrientation() }
    private func reveal(_ element: XCUIElement, _ app: XCUIApplication) { revealElement(element, app) }
    private func tap(_ id: String, _ app: XCUIApplication) {
        let item = app.buttons[id].firstMatch; reveal(item, app)
        XCTAssertTrue(item.waitForExistence(timeout: 5)); XCTAssertTrue(isRevealed(item, app), id + " " + whyNotRevealed(item, app)); item.tap()
    }
    private func wait(_ element: XCUIElement, contains: String) {
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "label CONTAINS %@", contains), evaluatedWith: element); waitForExpectations(timeout: 20)
    }
    /// Machine state keys travel in the accessibility value; the label is human copy.
    private func waitValue(_ element: XCUIElement, _ expected: String) {
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "value == %@", expected), evaluatedWith: element); waitForExpectations(timeout: 20)
    }
    private func navigate(_ title: String, _ app: XCUIApplication) {
        navigateTo(title, app)
    }
    private func fixture(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-synthetic-source", "--uitest-synthetic-detector", "--uitest-synthetic-faces", "--uitest-presentation-controls", "--uitest-catalog-token", UUID().uuidString] + extra
        app.launch(); tap("choose-folder", app); tap("start-scan", app); app.alerts.buttons["Start scan"].tap()
        waitValue(app.staticTexts["scan-phase"], "completed"); navigate("People", app)
        let face = app.buttons.matching(NSPredicate(format: "identifier == 'unidentified-face' AND label CONTAINS 'nested/synthetic-0.jpg'")).firstMatch
        reveal(face, app); XCTAssertTrue(isRevealed(face, app), whyNotRevealed(face, app)); face.tap()
        let field = app.textFields["new-person-name"]; XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("Fictional Alice")
        tap("save-selected-face", app); XCTAssertTrue(field.waitForNonExistence(timeout: 5)); return app
    }
    private func selectSearch(_ app: XCUIApplication) {
        navigate("Search", app)
        let chip = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'search-person-'" )).firstMatch
        reveal(chip, app); XCTAssertTrue(isRevealed(chip, app)); chip.tap(); tap("search-mode-any", app)
    }
    private func openPerson(_ app: XCUIApplication) {
        navigate("People", app)
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'person-'" )).firstMatch
        reveal(card, app); XCTAssertTrue(card.waitForExistence(timeout: 5)); card.tap()
        ensureEditingPersonName(app)
        XCTAssertTrue(app.textFields["rename-person-name"].waitForExistence(timeout: 5))
    }
    private func typeDraft(_ app: XCUIApplication) {
        let field = app.textFields["rename-person-name"]; field.tap(); field.typeText(" retained owner draft")
    }
    private func flush(_ app: XCUIApplication) {
        tap("flush-presentation-inputs", app)
        wait(app.staticTexts["presentation-persistence-probe"], contains: "Active 0")
    }
    func testCompletedSearchSurvivesNavigationAndModeChangeInvalidates() {
        let app = fixture(); selectSearch(app)
        wait(app.staticTexts["search-result-count"], contains: "photo")
        let count = app.staticTexts["search-result-count"].label
        navigate("Library", app); navigate("Search", app)
        XCTAssertEqual(app.staticTexts["search-result-count"].label, count)
        tap("search-mode-only", app); wait(app.staticTexts["search-result-count"], contains: "0 photos")
    }
    func testRelaunchRestoresInputsButRequiresFreshExplicitSearch() {
        let app = fixture(); selectSearch(app); wait(app.staticTexts["search-result-count"], contains: "photo"); flush(app)
        app.terminate(); app.launch(); navigate("Search", app)
        XCTAssertTrue(app.staticTexts["query-sentence"].label.contains("Fictional Alice")); XCTAssertFalse(app.staticTexts["search-result-count"].exists)
        tap("show-photos", app); wait(app.staticTexts["search-result-count"], contains: "photo")
    }
    func testDirtyDraftSurvivesNavigationAndRelaunch() {
        let app = fixture(); openPerson(app); typeDraft(app)
        let draft = app.textFields["rename-person-name"].value as? String
        navigate("Library", app); openPerson(app); XCTAssertEqual(app.textFields["rename-person-name"].value as? String, draft)
        flush(app); app.terminate(); app.launch(); openPerson(app)
        XCTAssertEqual(app.textFields["rename-person-name"].value as? String, draft)
    }
    func testCanonicalConflictUseCurrentDiscardsOnlyDraft() {
        let app = fixture(); openPerson(app); typeDraft(app); tap("change-canonical-fixture", app)
        wait(app.staticTexts["name-draft-conflict"], contains: "changed"); tap("use-current-name", app)
        XCTAssertEqual(app.textFields["rename-person-name"].value as? String, "Changed fictional name")
        XCTAssertFalse(app.staticTexts["name-draft-conflict"].exists)
    }
    func testFailedActualRenameKeepsDirtyInputAcrossNavigation() {
        let app = fixture(); openPerson(app)
        let field = app.textFields["rename-person-name"], previous = field.value as? String ?? ""
        _ = previous; clearAndType(field, "   ", app)
        tap("save-person-name", app); XCTAssertTrue(app.staticTexts["decision-error"].waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "   ")
        navigate("Library", app); openPerson(app); XCTAssertEqual(app.textFields["rename-person-name"].value as? String, "   ")
    }
    private func restore(_ app: XCUIApplication) {
        tap("settings", app); tap("choose-restore", app); waitValue(app.staticTexts["backup-operation-state"], "restorePreview")
        tap("confirm-catalog-restore", app)
    }
    func testActualCatalogReplacementResetsSavedInputsAndDirtyDraft() {
        let app = fixture(); selectSearch(app); openPerson(app); typeDraft(app); flush(app); navigate("Library", app)
        restore(app); waitValue(app.staticTexts["backup-operation-state"], "finished")
        wait(app.staticTexts["backup-operation-probe"], contains: "Adopt 1")
        app.buttons["Done"].tap(); navigate("Search", app)
        XCTAssertFalse(app.staticTexts["query-sentence"].label.contains("Fictional Alice")); XCTAssertFalse(app.staticTexts["search-result-count"].exists)
        openPerson(app); XCTAssertEqual(app.textFields["rename-person-name"].value as? String, "Fictional Alice")
    }
    func testCheckedOriginalAfterActualCancellationPreservesDraftAndFilterOnlyAfterExplicitRetry() {
        let app = fixture(["--uitest-backup-cancel-before-prepared", "--uitest-backup-hold-before-prepared"])
        selectSearch(app); openPerson(app); typeDraft(app); let draft = app.textFields["rename-person-name"].value as? String
        flush(app); navigate("Library", app); restore(app)
        wait(app.staticTexts["backup-test-status"], contains: "Held 1"); tap("release-backup-work", app)
        waitValue(app.staticTexts["backup-operation-state"], "recoveryRequired")
        XCTAssertTrue(app.staticTexts["backup-operation-probe"].label.contains("Adopt 0"))
        tap("retry-backup-operation", app); waitValue(app.staticTexts["backup-operation-state"], "finished")
        XCTAssertTrue(app.staticTexts["backup-operation-message"].label.contains("Original catalog preserved"))
        app.buttons["Done"].tap(); navigate("Search", app); XCTAssertTrue(app.staticTexts["query-sentence"].label.contains("Fictional Alice"))
        openPerson(app); XCTAssertEqual(app.textFields["rename-person-name"].value as? String, draft)
    }
}
