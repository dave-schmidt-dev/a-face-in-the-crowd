import XCTest

/// Synthetic local actions: authored/compiled here; the coordinated native gate executes them later.
final class PrivacyFlowTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false; applyRequestedOrientation() }
    private func app(_ flags: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-synthetic-source", "--uitest-synthetic-detector", "--uitest-synthetic-faces", "--uitest-session-controls", "--uitest-presentation-controls", "--uitest-catalog-token", UUID().uuidString] + flags
        app.launch(); XCTAssertTrue(app.buttons["choose-folder"].waitForExistence(timeout: 10)); return app
    }
    private func reveal(_ element: XCUIElement, _ app: XCUIApplication) { revealElement(element, app) }
    private func revealed(_ element: XCUIElement, _ app: XCUIApplication) -> Bool { isRevealed(element, app) }
    private func tap(_ id: String, _ app: XCUIApplication) {
        let element = app.buttons[id].firstMatch; reveal(element, app)
        XCTAssertTrue(element.waitForExistence(timeout: 10)); XCTAssertTrue(isRevealed(element, app), id + " " + whyNotRevealed(element, app)); element.tap()
    }
    private func wait(_ id: String, _ text: String, _ app: XCUIApplication) {
        let element = app.staticTexts[id]; XCTAssertTrue(element.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "label CONTAINS %@", text), evaluatedWith: element); waitForExpectations(timeout: 20)
    }
    /// Machine state keys travel in the accessibility value; the label is human copy.
    private func waitValue(_ id: String, _ expected: String, _ app: XCUIApplication) {
        let element = app.staticTexts[id]; XCTAssertTrue(element.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "value == %@", expected), evaluatedWith: element); waitForExpectations(timeout: 20)
    }
    private func navigate(_ title: String, _ app: XCUIApplication) {
        let control = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ OR label == %@", "navigate-" + title, title)).firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 10)); control.tap()
    }
    private func scan(_ app: XCUIApplication, completed: Bool = true) {
        tap("choose-folder", app); tap("start-scan", app); app.alerts.buttons["Start scan"].tap()
        if completed { waitValue("scan-phase", "completed", app) }
    }
    private func settings(_ app: XCUIApplication) { tap("settings", app) }
    private func confirm(_ action: String, _ app: XCUIApplication) {
        tap(action, app)
        let diagnostics = { "\(action) enabled=\(app.buttons[action].firstMatch.isEnabled) frame=\(app.buttons[action].firstMatch.frame) keyboard=\(app.keyboards.firstMatch.exists) alerts=\(app.alerts.allElementsBoundByIndex.map { $0.label })" }
        XCTAssertTrue(app.alerts["Confirm privacy action"].waitForExistence(timeout: 10), diagnostics()); app.alerts.buttons["Continue"].tap()
    }
    private func name(_ app: XCUIApplication, path: String = "nested/synthetic-0.jpg") {
        navigate("People", app)
        let face = app.buttons.matching(NSPredicate(format: "identifier == 'unidentified-face' AND label CONTAINS %@", path)).firstMatch
        reveal(face, app); XCTAssertTrue(face.waitForExistence(timeout: 10)); face.tap()
        let field = app.textFields["new-person-name"]; XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap(); field.typeText("Fictional Alice")
        tap("save-selected-face", app); XCTAssertTrue(field.waitForNonExistence(timeout: 10))
    }
    private func openPerson(_ app: XCUIApplication) {
        navigate("People", app)
        let person = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'person-'" )).firstMatch
        reveal(person, app); XCTAssertTrue(person.waitForExistence(timeout: 10)); person.tap()
        ensureEditingPersonName(app)
        XCTAssertTrue(app.textFields["rename-person-name"].waitForExistence(timeout: 10))
    }
    private func deletedProof(_ app: XCUIApplication, copies: Int = 0, originals: Int = 3) {
        wait("privacy-operation-state", "finished", app)
        tap("verify-deletion-fixture", app)
        wait("privacy-deletion-fixture-probe", "Absent 1 · Original files checked \(originals) · Copies retained \(copies) · Late log absent 1", app)
        app.buttons["Done"].tap(); XCTAssertTrue(app.staticTexts["local-catalog-deleted"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["choose-folder"].exists); XCTAssertFalse(app.buttons["retry-catalog-startup"].exists)
    }
    func testWholeDeletionWaitsForHeldActualSourceDrainThenProvesNoLateCatalogOrLogger() {
        let app = app(["--uitest-privacy-controls", "--uitest-session-hold-scan"]); scan(app, completed: false)
        wait("catalog-session-probe", "Held 1", app); settings(app); confirm("delete-local-catalog", app)
        wait("privacy-operation-state", "draining", app); XCTAssertFalse(app.staticTexts["local-catalog-deleted"].exists)
        tap("settings-release-session-work", app); deletedProof(app)
    }
    func testWholeDeletionAfterRealExportAndImportCancelPreservesExternalCopiesAndOriginals() {
        let app = app(["--uitest-privacy-controls"]); scan(app); name(app); settings(app)
        tap("prepare-backup", app); waitValue("backup-operation-state", "exportPreview", app)
        tap("choose-backup-destination", app); wait("backup-operation-probe", "Active 0", app)
        tap("confirm-backup-export", app); waitValue("backup-operation-state", "finished", app)
        tap("choose-restore", app); waitValue("backup-operation-state", "restorePreview", app)
        tap("cancel-restore-preview", app); waitValue("backup-operation-state", "idle", app)
        confirm("delete-local-catalog", app); deletedProof(app, copies: 2)
        settings(app); tap("cleanup-deletion-fixture", app); wait("privacy-deletion-fixture-probe", "Owned synthetic copies cleaned", app)
    }
    func testWholeDeletionPreferenceFailureRetainsSameCoreOwnerAndDoesNotPublishEmptySuccess() {
        let app = app(["--uitest-privacy-controls", "--uitest-presentation-save-retry"]); scan(app); name(app); openPerson(app)
        let field = app.textFields["rename-person-name"]; field.tap(); field.typeText(" retained owner draft")
        tap("flush-presentation-inputs", app); wait("presentation-persistence-probe", "Active 0", app)
        tap("block-presentation-save", app); wait("presentation-save-fixture-probe", "blocked", app); settings(app)
        confirm("delete-local-catalog", app); wait("privacy-operation-state", "cleanupRequired", app)
        wait("privacy-completed-cleanup", "Diagnostics, import staging", app); wait("privacy-operation-probe", "Whole owners 1", app)
        XCTAssertFalse(app.staticTexts["local-catalog-deleted"].exists)
        tap("privacy-repair-inputs", app); wait("privacy-input-fixture", "repaired", app)
        tap("retry-privacy-action", app); wait("privacy-operation-probe", "Whole owners 1", app); deletedProof(app)
    }
    func testWholeDeletionRefusesRetainedRestoreOwnerWithoutStartingCleanup() {
        let app = app(["--uitest-privacy-controls", "--uitest-backup-prepared-fault"]); settings(app)
        tap("choose-restore", app); waitValue("backup-operation-state", "restorePreview", app)
        tap("confirm-catalog-restore", app); waitValue("backup-operation-state", "recoveryRequired", app)
        tap("delete-local-catalog", app); wait("privacy-operation-message", "Finish catalog recovery", app)
        XCTAssertFalse(app.alerts["Confirm privacy action"].exists); XCTAssertFalse(app.staticTexts["local-catalog-deleted"].exists)
        wait("backup-operation-probe", "Restore 1 · Open 0 · Adopt 0", app)
        tap("retry-backup-operation", app); waitValue("backup-operation-state", "finished", app)
        confirm("delete-local-catalog", app); deletedProof(app, copies: 1, originals: 0)
        settings(app); tap("cleanup-deletion-fixture", app); wait("privacy-deletion-fixture-probe", "Owned synthetic copies cleaned", app)
    }

    func testDisconnectWaitsForActualSourceWorkerCompletionAndPreventsLateSelection() {
        let app = app(["--uitest-session-hold-scan"]); scan(app, completed: false)
        wait("catalog-session-probe", "Held 1", app); settings(app); confirm("disconnect-source", app)
        wait("privacy-operation-state", "draining", app)
        XCTAssertEqual(app.staticTexts["backup-source-state"].label, "Original source folder selected")
        tap("settings-release-session-work", app); wait("privacy-operation-state", "finished", app)
        XCTAssertEqual(app.staticTexts["backup-source-state"].label, "No source folder selected")
        wait("privacy-operation-probe", "Effects 1 · Adopt 1", app)
    }
    func testOfflineCacheClearRetainsDecisionsAndExplainsUnavailablePreviews() {
        let app = app(); scan(app); name(app); settings(app); confirm("disconnect-source", app)
        wait("privacy-operation-state", "finished", app); confirm("clear-cached-previews", app)
        wait("privacy-operation-state", "finished", app)
        XCTAssertTrue(app.staticTexts["privacy-operation-message"].label.contains("Offline previews are unavailable"))
        app.buttons["Done"].tap(); openPerson(app)
        XCTAssertEqual(app.textFields["rename-person-name"].value as? String, "Fictional Alice")
        XCTAssertTrue(app.staticTexts["person-confirmed-count"].label.contains("1 confirmed"))
    }
    func testPersonDeletionPreservesEqualNamePeerAndDisclosesRetainedHistoryAndExports() {
        let app = app(); scan(app); name(app); name(app, path: "nested/synthetic-1.jpg"); openPerson(app)
        tap("delete-person", app)
        let alert = app.alerts["Confirm privacy action"]; XCTAssertTrue(alert.waitForExistence(timeout: 10))
        XCTAssertTrue(alert.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Immutable history and prior exports'" )).firstMatch.exists)
        alert.buttons["Continue"].tap(); settings(app); wait("privacy-operation-state", "finished", app)
        XCTAssertTrue(app.staticTexts["privacy-operation-message"].label.contains("related Undo is unavailable"))
        app.buttons["Done"].tap(); navigate("People", app)
        // Rows below the fold are not rendered by the lazy grid, so the count is read from the heading's value.
        let heading = app.staticTexts["people-records-start"]; XCTAssertTrue(heading.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntilTrue(10) { heading.value as? String == "1" }, "people count: \(heading.value ?? "nil")")
    }
    func testCommittedPreferenceCleanupRetryNeverDeletesAgain() {
        let app = app(["--uitest-presentation-save-retry"]); scan(app); name(app); openPerson(app)
        let field = app.textFields["rename-person-name"]; field.tap(); field.typeText(" owner draft")
        tap("flush-presentation-inputs", app); wait("presentation-persistence-probe", "Active 0", app)
        tap("block-presentation-save", app); wait("presentation-save-fixture-probe", "blocked", app)
        confirm("delete-person", app); tap("privacy-open-settings", app)
        wait("privacy-operation-state", "cleanupRequired", app); wait("privacy-operation-probe", "Deletes 1", app)
        tap("privacy-repair-inputs", app); wait("privacy-input-fixture", "repaired", app)
        tap("retry-privacy-action", app); wait("privacy-operation-state", "finished", app)
        wait("privacy-operation-probe", "Deletes 1 · Effects 1 · Adopt 1", app)
    }
    func testRetainedRestoreOwnerRefusesPrivacyActionsWithoutCompetingRecovery() {
        let app = app(["--uitest-backup-prepared-fault"]); settings(app)
        tap("choose-restore", app); waitValue("backup-operation-state", "restorePreview", app)
        tap("confirm-catalog-restore", app); waitValue("backup-operation-state", "recoveryRequired", app)
        tap("clear-cached-previews", app)
        wait("privacy-operation-message", "Finish catalog recovery", app)
        XCTAssertFalse(app.alerts["Confirm privacy action"].exists)
        wait("backup-operation-probe", "Restore 1 · Open 0 · Adopt 0", app)
    }
    func testDrainTimeoutKeepsCatalogFencedUntilExplicitRetry() {
        let app = app(["--uitest-session-hold-people", "--uitest-session-short-timeout"])
        wait("catalog-session-probe", "Held 1", app); settings(app); confirm("clear-cached-previews", app)
        wait("privacy-operation-state", "retryRequired", app); wait("privacy-operation-probe", "Effects 0", app)
        tap("settings-release-session-work", app); wait("settings-session-probe", "Active 0", app)
        XCTAssertTrue(app.staticTexts["privacy-operation-state"].label.contains("retryRequired"))
        tap("retry-privacy-action", app); wait("privacy-operation-state", "finished", app)
        wait("privacy-operation-probe", "Effects 1 · Adopt 1", app)
    }
}
