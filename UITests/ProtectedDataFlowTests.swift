import XCTest

/// Actual generated-fixture workers; authored and compiled only until the coordinated native gate.
final class ProtectedDataFlowTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func launch(_ flags: [String] = [], token: String = UUID().uuidString) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-synthetic-source", "--uitest-synthetic-detector", "--uitest-synthetic-faces",
            "--uitest-session-controls", "--uitest-protected-controls", "--uitest-catalog-token", token] + flags
        app.launch(); return app
    }
    /// Prefers a hittable match: some test-support ids exist both in the root inset and in a presented sheet.
    private func hittableButton(_ id: String, _ app: XCUIApplication) -> XCUIElement? {
        let matches = app.buttons.matching(identifier: id).allElementsBoundByIndex
        if matches.count > 1 {
            print("[ui-probe] \(id) matches=\(matches.count) " + matches.map { "hittable=\($0.isHittable) frame=\($0.frame)" }.joined(separator: "; "))
        }
        return matches.first { $0.exists && $0.isHittable }
    }
    private func tap(_ id: String, _ app: XCUIApplication) {
        var button = app.buttons[id].firstMatch, found = false
        for _ in 0..<12 { if let match = hittableButton(id, app) { button = match; found = true; break }; app.swipeUp() }
        if !found { for _ in 0..<16 { if let match = hittableButton(id, app) { button = match; break }; app.swipeDown() } }
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: button)
        waitForExpectations(timeout: 10); XCTAssertTrue(button.isHittable); button.tap()
    }
    private func wait(_ id: String, _ fragment: String, _ app: XCUIApplication) {
        let label = app.staticTexts[id]; XCTAssertTrue(label.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "label CONTAINS %@", fragment), evaluatedWith: label)
        waitForExpectations(timeout: 20)
    }
    private func navigate(_ section: String, _ app: XCUIApplication) {
        let button = app.descendants(matching: .any).matching(NSPredicate(format:
            "identifier == %@ OR label == %@", "navigate-" + section, section)).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10)); button.tap()
    }
    /// Leaves Person detail through its own back button; index 0 of all bars can be the split-view sidebar toggle.
    private func backFromPerson(_ app: XCUIApplication) {
        let bar = app.navigationBars["Person"]; XCTAssertTrue(bar.waitForExistence(timeout: 10))
        let back = bar.buttons.matching(NSPredicate(format: "label IN %@ OR identifier == 'BackButton'", ["People", "Back"])).firstMatch
        let buttons = bar.buttons.allElementsBoundByIndex.map { "\($0.label)|\($0.identifier)|hittable=\($0.isHittable)" }
        XCTAssertTrue(back.waitForExistence(timeout: 10), "Person bar buttons: \(buttons)")
        back.tap(); XCTAssertTrue(bar.waitForNonExistence(timeout: 10))
    }
    private func scan(_ app: XCUIApplication, completed: Bool = true) {
        tap("choose-folder", app); tap("start-scan", app); app.alerts.buttons["Start scan"].tap()
        if completed { wait("scan-phase", "Completed", app) }
    }
    private func assertClosed(_ app: XCUIApplication, reopen: Bool = true) {
        wait("protected-catalog-state", "closed", app)
        wait("protected-session-probe", "Active 0", app)
        XCTAssertFalse(app.buttons["choose-folder"].exists)
        XCTAssertFalse(app.buttons["retry-catalog-startup"].exists)
        XCTAssertFalse(app.scrollViews["screen-Library"].exists)
        tap("protected-synthetic-did", app)
        wait("protected-catalog-message", "Explicitly", app)
        XCTAssertFalse(app.buttons["choose-folder"].exists)
        if reopen {
            tap("open-protected-catalog", app)
            // Reopen keeps the selected section; Library is where the reopened catalog offers choose-folder.
            navigate("Library", app)
            XCTAssertTrue(app.buttons["choose-folder"].waitForExistence(timeout: 10))
        }
    }
    func testLockedColdLaunchDoesNotAdmitStartupOrSourceAndAvailableEventStaysGated() {
        let token = UUID().uuidString
        let seed = launch(token: token)
        XCTAssertTrue(seed.buttons["choose-folder"].waitForExistence(timeout: 10)); seed.terminate()
        let app = launch(["--uitest-protected-cold-lock"], token: token)
        wait("protected-catalog-state", "coldLocked", app)
        wait("protected-session-probe", "Active 0", app)
        XCTAssertFalse(app.buttons["choose-folder"].exists)
        XCTAssertFalse(app.buttons["retry-catalog-startup"].exists)
        tap("protected-probe-admission", app)
        wait("protected-session-probe", "Active 0", app)
        tap("protected-synthetic-did", app)
        wait("protected-catalog-state", "coldLocked", app)
        XCTAssertFalse(app.buttons["choose-folder"].exists)
        tap("open-protected-catalog", app)
        XCTAssertTrue(app.buttons["choose-folder"].waitForExistence(timeout: 10))
    }
    func testActualPreferenceWriterKeepsDrainPendingUntilExplicitRelease() {
        let app = launch(["--uitest-protected-hold-preferences", "--uitest-session-short-timeout"])
        XCTAssertTrue(app.buttons["choose-folder"].waitForExistence(timeout: 10))
        navigate("Search", app); tap("search-mode-any", app)
        wait("catalog-session-probe", "presentation-write", app)
        tap("protected-synthetic-will", app)
        wait("protected-fixture-probe", "preference-writer", app)
        wait("protected-catalog-state", "retryRequired", app)
        XCTAssertFalse(app.buttons["choose-folder"].exists)
        tap("protected-release-workers", app)
        wait("protected-session-probe", "Active 0", app)
        XCTAssertEqual(app.staticTexts["protected-catalog-state"].label, "retryRequired")
        tap("retry-protected-close", app); assertClosed(app)
    }
    func testLateActualScanCompletionRequiresExplicitRedrainBeforePhysicalClose() {
        let app = launch(["--uitest-session-hold-scan", "--uitest-session-short-timeout"])
        scan(app, completed: false); wait("catalog-session-probe", "Held 1", app)
        tap("protected-synthetic-will", app)
        wait("protected-catalog-state", "retryRequired", app)
        tap("protected-synthetic-did", app)
        XCTAssertEqual(app.staticTexts["protected-catalog-state"].label, "retryRequired")
        tap("protected-release-workers", app)
        wait("protected-session-probe", "Active 0", app)
        XCTAssertTrue(app.staticTexts["protected-session-probe"].label.contains("Drained 0"))
        tap("retry-protected-close", app); assertClosed(app)
    }
    func testRealSQLiteBusyKeepsSameFenceUntilStatementReleaseAndExplicitRetry() {
        let app = launch(["--uitest-protected-sqlite-busy"])
        XCTAssertTrue(app.buttons["choose-folder"].waitForExistence(timeout: 10))
        tap("protected-synthetic-will", app)
        wait("protected-catalog-state", "retryRequired", app)
        wait("protected-catalog-message", "same owner", app)
        tap("protected-synthetic-did", app)
        XCTAssertEqual(app.staticTexts["protected-catalog-state"].label, "retryRequired")
        tap("protected-release-workers", app)
        tap("retry-protected-close", app); assertClosed(app)
    }
    func testEachActualLibraryFaceAndSearchPreviewWorkerDelaysDrainAndCannotPublishLate() {
        for kind in ["library-preview", "face-preview", "search-preview"] {
            let app = launch(["--uitest-protected-hold-previews", "--uitest-protected-preview-kind", kind,
                "--uitest-session-short-timeout"])
            scan(app)
            if kind == "face-preview" { navigate("People", app) }
            if kind == "search-preview" { navigate("Search", app); tap("show-photos", app) }
            wait("catalog-session-probe", kind, app)
            tap("protected-synthetic-will", app)
            wait("protected-catalog-state", "retryRequired", app)
            XCTAssertFalse(app.scrollViews["screen-Library"].exists)
            XCTAssertFalse(app.scrollViews["screen-People"].exists)
            XCTAssertFalse(app.scrollViews["screen-Search"].exists)
            tap("protected-release-workers", app)
            wait("protected-session-probe", "Active 0", app)
            XCTAssertEqual(app.staticTexts["protected-catalog-state"].label, "retryRequired")
            tap("retry-protected-close", app); assertClosed(app); app.terminate()
        }
    }
    func testLockDuringActualPreparedDeletionOwnerClosesWithoutContinuingErase() {
        let app = launch(["--uitest-protected-hold-deletion", "--uitest-session-short-timeout"])
        XCTAssertTrue(app.buttons["choose-folder"].waitForExistence(timeout: 10))
        tap("settings", app); tap("prepare-backup", app)
        wait("backup-operation-state", "exportPreview", app)
        tap("delete-local-catalog", app)
        XCTAssertTrue(app.alerts["Confirm privacy action"].waitForExistence(timeout: 10))
        app.alerts["Confirm privacy action"].buttons["Continue"].tap()
        wait("privacy-operation-probe", "Whole owners 1", app)
        wait("privacy-completed-cleanup", "Diagnostics, import staging", app)
        tap("protected-synthetic-will", app)
        wait("protected-retained-backup-probe", "Prepared 0", app)
        wait("protected-catalog-state", "retryRequired", app)
        XCTAssertFalse(app.staticTexts["local-catalog-deleted"].exists)
        tap("protected-release-workers", app)
        tap("retry-protected-close", app); assertClosed(app, reopen: false)
        XCTAssertFalse(app.staticTexts["local-catalog-deleted"].exists)
        tap("open-protected-catalog", app)
        XCTAssertTrue(app.staticTexts["local-catalog-deleted"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["choose-folder"].exists)
    }

    private func nameAndOpen(_ app: XCUIApplication) {
        navigate("People", app)
        let face = app.buttons.matching(NSPredicate(format: "identifier == 'unidentified-face' AND label CONTAINS 'nested/synthetic-0.jpg'")).firstMatch
        for _ in 0..<12 { if face.exists && face.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(face.waitForExistence(timeout: 10)); face.tap()
        let field = app.textFields["new-person-name"]; XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap(); field.typeText("Fictional Alice"); tap("save-selected-face", app)
        XCTAssertTrue(field.waitForNonExistence(timeout: 10))
        let person = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'person-'" )).firstMatch
        XCTAssertTrue(person.waitForExistence(timeout: 10)); person.tap()
        XCTAssertTrue(app.textFields["rename-person-name"].waitForExistence(timeout: 10))
    }
    func testDirtyDraftAndSearchInputsSurviveOrdinaryUnlockWithoutSourceReadOrScan() {
        let app = launch(); scan(app); nameAndOpen(app)
        let rename = app.textFields["rename-person-name"]; rename.tap(); rename.typeText(" retained owner input")
        backFromPerson(app)
        navigate("Search", app); tap("search-mode-any", app)
        tap("protected-synthetic-will", app); assertClosed(app)
        navigate("Search", app)
        XCTAssertTrue(app.buttons["search-mode-any"].isSelected)
        navigate("People", app)
        let person = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'person-'" )).firstMatch
        XCTAssertTrue(person.waitForExistence(timeout: 10)); person.tap()
        XCTAssertEqual(app.textFields["rename-person-name"].value as? String, "Fictional Alice retained owner input")
        backFromPerson(app); navigate("Library", app)
        wait("scan-phase", "Completed", app)
        tap("settings", app); XCTAssertEqual(app.staticTexts["backup-source-state"].label, "Original source folder selected")
    }
    func testRetainedPreparedRestoreOwnerLockAndExplicitUnlockUsesSameRecoveryAuthority() {
        let app = launch(["--uitest-privacy-controls", "--uitest-backup-prepared-fault"])
        scan(app); tap("settings", app); tap("choose-restore", app)
        wait("backup-operation-state", "restorePreview", app); tap("confirm-catalog-restore", app)
        wait("backup-operation-state", "recoveryRequired", app)
        wait("backup-operation-probe", "Restore 1 · Open 0 · Adopt 0", app)
        tap("protected-synthetic-will", app); assertClosed(app)
        tap("settings", app); XCTAssertEqual(app.staticTexts["backup-source-state"].label, "No source folder selected")
        XCTAssertFalse(app.staticTexts["backup-operation-state"].label.contains("recoveryRequired"))
        XCTAssertFalse(app.buttons["start-scan"].exists)
    }
    func testUnavailableAgainDuringFreshSnapshotRetainsActorAndPreventsLatePublication() {
        let app = launch(["--uitest-protected-hold-fresh-snapshot", "--uitest-session-short-timeout"])
        scan(app); nameAndOpen(app)
        backFromPerson(app)
        let personID = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'person-'" )).firstMatch.identifier
        navigate("Library", app); wait("scan-phase", "Completed", app)
        tap("settings", app); tap("prepare-backup", app)
        wait("backup-operation-state", "exportPreview", app)
        XCTAssertEqual(app.staticTexts["backup-source-state"].label, "Original source folder selected")
        tap("protected-synthetic-will", app); assertClosed(app, reopen: false)
        tap("open-protected-catalog", app)
        wait("protected-fixture-probe", "fresh-snapshot", app)
        XCTAssertFalse(app.buttons["choose-folder"].exists)
        tap("protected-synthetic-will", app)
        wait("protected-catalog-state", "retryRequired", app)
        wait("protected-retained-backup-probe", "Prepared 1 · Same owner and stage 1", app)
        tap("protected-release-workers", app)
        XCTAssertFalse(app.buttons["choose-folder"].exists)
        XCTAssertEqual(app.staticTexts["protected-catalog-state"].label, "retryRequired")
        tap("retry-protected-close", app); assertClosed(app)
        wait("protected-retained-backup-probe", "Prepared 0", app)
        navigate("Library", app); wait("scan-phase", "Completed", app)
        navigate("People", app)
        XCTAssertTrue(app.buttons[personID].waitForExistence(timeout: 10)); app.buttons[personID].tap()
        XCTAssertEqual(app.textFields["rename-person-name"].value as? String, "Fictional Alice")
        backFromPerson(app)
        tap("settings", app); wait("backup-operation-state", "idle", app)
        XCTAssertEqual(app.staticTexts["backup-source-state"].label, "Original source folder selected")
        XCTAssertFalse(app.buttons["retry-backup-operation"].exists)
        // A subsequent real preparation/cancel cannot resurrect the already consumed old stage.
        tap("prepare-backup", app); wait("backup-operation-state", "exportPreview", app)
        tap("cancel-backup-preview", app); wait("backup-operation-state", "idle", app)
        app.buttons["Done"].tap(); wait("protected-retained-backup-probe", "Prepared 0", app)
    }
    func testMissingExistingCatalogAfterLockShowsRecoveryAndNeverCreatesEmptyCatalog() {
        let token = UUID().uuidString
        let seed = launch(token: token)
        XCTAssertTrue(seed.buttons["choose-folder"].waitForExistence(timeout: 10))
        tap("settings", seed); tap("delete-local-catalog", seed)
        XCTAssertTrue(seed.alerts["Confirm privacy action"].waitForExistence(timeout: 10)); seed.alerts.buttons["Continue"].tap()
        wait("privacy-operation-state", "finished", seed); seed.terminate()
        let app = launch(["--uitest-protected-cold-lock"], token: token)
        wait("protected-catalog-state", "coldLocked", app)
        tap("protected-synthetic-did", app); XCTAssertFalse(app.buttons["choose-folder"].exists)
        tap("open-protected-catalog", app); wait("protected-catalog-state", "openRetryRequired", app)
        XCTAssertFalse(app.buttons["choose-folder"].exists)
        tap("open-protected-catalog", app); wait("protected-catalog-state", "openRetryRequired", app)
        XCTAssertFalse(app.buttons["choose-folder"].exists)
    }
    func testPausedLoggerActualQueuedRecordCannotRecreateAfterWholeDeleteAndResume() {
        let app = launch(["--uitest-privacy-controls", "--uitest-protected-hold-deletion", "--uitest-session-short-timeout"])
        XCTAssertTrue(app.buttons["choose-folder"].waitForExistence(timeout: 10))
        tap("settings", app); tap("delete-local-catalog", app)
        XCTAssertTrue(app.alerts["Confirm privacy action"].waitForExistence(timeout: 10)); app.alerts.buttons["Continue"].tap()
        wait("privacy-operation-probe", "Whole owners 1", app)
        tap("protected-synthetic-will", app); wait("protected-catalog-state", "retryRequired", app)
        tap("protected-release-workers", app); tap("retry-protected-close", app); assertClosed(app, reopen: false)
        tap("open-protected-catalog", app)
        XCTAssertTrue(app.staticTexts["local-catalog-deleted"].waitForExistence(timeout: 10))
        tap("settings", app); tap("verify-deletion-fixture", app)
        wait("privacy-deletion-fixture-probe", "Late log absent 1", app)
        XCTAssertFalse(app.buttons["choose-folder"].exists)
    }
}
