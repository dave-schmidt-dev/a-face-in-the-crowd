import XCTest

/// Authored causal lifecycle tests. These do not establish backup or device qualification.
final class BackupFlowTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false; applyRequestedOrientation() }
    private func backupApp(_ flags: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-synthetic-source", "--uitest-synthetic-detector", "--uitest-session-controls"] + flags
        app.launch()
        XCTAssertTrue(app.buttons["choose-folder"].waitForExistence(timeout: 10))
        let settings = app.buttons["settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10)); settings.tap()
        XCTAssertTrue(app.staticTexts["backup-privacy-warning"].waitForExistence(timeout: 5))
        return app
    }
    private func backupWait(_ state: String, _ app: XCUIApplication) {
        let element = app.staticTexts["backup-operation-state"]
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "value == %@", state), evaluatedWith: element)
        waitForExpectations(timeout: 20)
    }
    private func backupProbe(_ fragment: String, _ app: XCUIApplication) {
        let element = app.staticTexts["backup-operation-probe"]
        expectation(for: NSPredicate(format: "label CONTAINS %@", fragment), evaluatedWith: element)
        waitForExpectations(timeout: 20)
    }
    private func backupTap(_ id: String, _ app: XCUIApplication) {
        let button = app.buttons[id]; XCTAssertTrue(button.waitForExistence(timeout: 10))
        reveal(button, app: app); XCTAssertTrue(isRevealed(button, app), id + " " + whyNotRevealed(button, app)); button.tap()
    }
    private func prepareBackup(_ app: XCUIApplication) {
        backupTap("prepare-backup", app); backupWait("exportPreview", app); backupProbe("Active 0", app)
    }
    private func restorePreview(_ app: XCUIApplication) {
        backupTap("choose-restore", app); backupWait("restorePreview", app); backupProbe("Active 0", app)
    }
    func testBackupPreviewShowsExactRevisionCategoriesSizeAndUnencryptedExclusionsBeforeDestinationWrite() {
        let app = backupApp(); prepareBackup(app)
        let summary = app.staticTexts["backup-preview-summary"].label
        XCTAssertTrue(summary.contains("Revision 0")); XCTAssertTrue(summary.contains("0 photos"))
        XCTAssertNotNil(summary.range(of: "[1-9][0-9]* bytes", options: .regularExpression))
        XCTAssertTrue(app.staticTexts["backup-privacy-warning"].label.contains("unencrypted"))
        XCTAssertTrue(app.staticTexts["backup-included-categories"].label.contains("manual decisions"))
        XCTAssertFalse(app.buttons["confirm-backup-export"].exists)
        backupTap("cancel-backup-preview", app); backupWait("idle", app)
        XCTAssertTrue(app.staticTexts["backup-operation-message"].label.contains("unchanged"))
    }
    func testDestinationCancelAndCollisionPreserveExistingItemsAndCleanOnlyOwnedOutput() {
        let app = backupApp(["--uitest-backup-collision"]); prepareBackup(app)
        backupTap("cancel-backup-preview", app); backupWait("idle", app)
        prepareBackup(app); backupTap("choose-backup-destination", app); backupProbe("Active 0", app)
        XCTAssertTrue(app.buttons["confirm-backup-export"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["backup-volume-warning"].label.contains("not survive"))
        backupTap("confirm-backup-export", app); backupWait("failed", app); backupProbe("Active 0", app)
        XCTAssertTrue(app.staticTexts["backup-test-status"].label.contains("Collision 1 · Sentinel 1"))
        XCTAssertFalse(app.staticTexts["backup-operation-message"].label.contains("exported"))
        backupTap("retry-backup-operation", app); backupWait("idle", app)
    }
    func testValidatedRestorePreviewCancelPreservesCatalogAndSourceSelection() {
        let app = backupApp(["--uitest-backup-hold-validation"])
        let before = app.staticTexts["backup-source-state"].label
        backupTap("choose-restore", app)
        let held = app.staticTexts["backup-test-status"]
        expectation(for: NSPredicate(format: "label CONTAINS 'Held 1'"), evaluatedWith: held); waitForExpectations(timeout: 10)
        XCTAssertFalse(app.buttons["confirm-catalog-restore"].exists)
        backupTap("release-backup-work", app); backupWait("restorePreview", app); backupProbe("Active 0", app)
        XCTAssertTrue(app.staticTexts["restore-replacement-warning"].label.contains("does not merge"))
        XCTAssertTrue(app.staticTexts["restore-current-revision"].label.contains("revision 0"))
        backupTap("cancel-restore-preview", app); backupWait("idle", app)
        XCTAssertEqual(app.staticTexts["backup-source-state"].label, before); backupProbe("Restore 0 · Open 0 · Adopt 0", app)
    }
    func testInvalidImportCannotReachReplacementConfirmationOrMutateLiveCatalog() {
        let app = backupApp(["--uitest-backup-invalid"])
        let before = app.staticTexts["backup-source-state"].label
        backupTap("choose-restore", app); backupWait("failed", app); backupProbe("Active 0", app)
        XCTAssertFalse(app.buttons["confirm-catalog-restore"].exists)
        XCTAssertEqual(app.staticTexts["backup-source-state"].label, before)
        backupProbe("Restore 0 · Open 0 · Adopt 0", app)
    }
    func testRestoreDrainTimeoutRequiresExplicitRetryBeforeSingleGraphPublicationAndReconnect() {
        let app = backupApp(["--uitest-session-hold-people", "--uitest-session-short-timeout"])
        restorePreview(app); backupTap("confirm-catalog-restore", app); backupWait("recoveryRequired", app)
        backupProbe("Restore 0 · Open 0 · Adopt 0", app)
        backupTap("settings-release-session-work", app)
        let session = app.staticTexts["settings-session-probe"]
        expectation(for: NSPredicate(format: "label CONTAINS 'Active 0'"), evaluatedWith: session); waitForExpectations(timeout: 10)
        XCTAssertTrue(session.label.contains("TimedOut 1")); backupProbe("Adopt 0", app)
        backupTap("retry-backup-operation", app); backupWait("finished", app); backupProbe("Adopt 1", app)
        XCTAssertEqual(app.staticTexts["backup-source-state"].label, "No source folder selected")
        XCTAssertTrue(app.staticTexts["backup-operation-message"].label.contains("Reconnect"))
    }
    func testFailedRecoveryRetainsCoordinatorAndExplicitRetryWithoutCompetingOpen() {
        let app = backupApp(["--uitest-backup-prepared-fault"])
        restorePreview(app); backupTap("confirm-catalog-restore", app); backupWait("recoveryRequired", app)
        backupProbe("Restore 1 · Open 0 · Adopt 0 · Returned 0", app)
        backupTap("retry-backup-operation", app); backupWait("finished", app)
        backupProbe("Restore 1 · Open 1 · Adopt 1", app)
        XCTAssertEqual(app.staticTexts["backup-source-state"].label, "No source folder selected")
    }
    func testReturnedFreshActorSurvivesSnapshotFailureUntilExplicitReadRetry() {
        let app = backupApp(["--uitest-backup-snapshot-fault"])
        restorePreview(app); backupTap("confirm-catalog-restore", app); backupWait("recoveryRequired", app)
        backupProbe("Restore 1 · Open 0 · Adopt 0 · Returned 1", app)
        backupTap("retry-backup-operation", app); backupWait("finished", app)
        backupProbe("Restore 1 · Open 0 · Adopt 1", app)
    }
    func testProgressCoalescesWithoutPerRowTasksAndKeepsTerminalOutcome() {
        let app = backupApp(["--uitest-backup-hold-progress"])
        backupTap("prepare-backup", app)
        let held = app.staticTexts["backup-test-status"]
        expectation(for: NSPredicate(format: "label CONTAINS 'Held 1'"), evaluatedWith: held); waitForExpectations(timeout: 10)
        backupProbe("Active 1", app); backupTap("release-backup-work", app)
        backupWait("exportPreview", app); backupProbe("Active 0", app)
        XCTAssertNotNil(app.staticTexts["backup-operation-probe"].label.range(of: "Dropped [1-9][0-9]*", options: .regularExpression))
        XCTAssertTrue(app.staticTexts["backup-preview-summary"].exists)
        backupTap("cancel-backup-preview", app); backupWait("idle", app)
    }
    private func launch(hold: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-synthetic-source", "--uitest-synthetic-detector",
            "--uitest-session-controls", "--uitest-session-hold-" + hold]
        app.launch()
        return app
    }
    private func wait(_ fragment: String, app: XCUIApplication) {
        let probe = app.staticTexts["catalog-session-probe"]
        XCTAssertTrue(probe.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "label CONTAINS %@", fragment), evaluatedWith: probe)
        waitForExpectations(timeout: 10)
    }
    private func pauseAndDrain(_ app: XCUIApplication) {
        app.buttons["quiesce-session"].tap()
        XCTAssertTrue(app.staticTexts["catalog-session-quiescing"].waitForExistence(timeout: 5))
        wait("Held 1", app: app)
        XCTAssertFalse(app.staticTexts["catalog-session-probe"].label.contains("Drained 1"))
        let before = app.staticTexts["catalog-session-probe"].label
        app.buttons["probe-session-admission"].tap()
        XCTAssertEqual(app.staticTexts["catalog-session-probe"].label, before,
                       "Closed admission must not start a fixture worker")
        app.buttons["release-session-work"].tap()
        wait("Drained 1", app: app)
        wait("Active 0", app: app)
        XCTAssertTrue(app.staticTexts["catalog-session-quiescing"].exists,
                      "Drain does not automatically resume or swap a catalog")
    }
    func testHeldStartupMustActuallyFinishBeforeDrainWithoutLateSourcePublication() {
        let app = launch(hold: "startup")
        wait("Held 1", app: app)
        pauseAndDrain(app)
        XCTAssertFalse(app.staticTexts["setup-error"].exists)
        XCTAssertFalse(app.images["Photo preview"].exists)
    }
    func testHeldPeopleReadCannotPublishOrSpawnDirtySuccessorAfterQuiescence() {
        let app = launch(hold: "people")
        wait("Held 1", app: app)
        pauseAndDrain(app)
        XCTAssertFalse(app.staticTexts["people-refresh-warning"].exists)
        XCTAssertFalse(app.staticTexts["decision-error"].exists)
    }
    func testFiniteTimeoutRetainsHeldWorkerAndClosedAdmissionUntilActualFinish() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-synthetic-source", "--uitest-synthetic-detector",
            "--uitest-session-controls", "--uitest-session-hold-startup", "--uitest-session-short-timeout"]
        app.launch(); wait("Held 1", app: app)
        app.buttons["quiesce-session"].tap()
        XCTAssertTrue(app.staticTexts["catalog-session-quiescing"].waitForExistence(timeout: 5))
        wait("TimedOut 1", app: app)
        wait("Held 1", app: app)
        XCTAssertFalse(app.staticTexts["catalog-session-probe"].label.contains("Drained 1"))
        app.buttons["release-session-work"].tap(); wait("Active 0", app: app)
        XCTAssertFalse(app.staticTexts["catalog-session-probe"].label.contains("Drained 1"))
        XCTAssertTrue(app.staticTexts["catalog-session-quiescing"].exists)
        app.buttons["probe-session-admission"].tap(); wait("Active 0", app: app)
    }
    func testTimedOutSessionRequiresExplicitRedrainAfterActualWorkerFinishes() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-synthetic-source", "--uitest-synthetic-detector",
            "--uitest-session-controls", "--uitest-session-hold-startup", "--uitest-session-short-timeout"]
        app.launch(); wait("Held 1", app: app)
        app.buttons["quiesce-session"].tap(); wait("TimedOut 1", app: app)
        let epoch = app.staticTexts["catalog-session-probe"].label.components(separatedBy: " · ").first
        app.buttons["release-session-work"].tap(); wait("Active 0", app: app)
        wait("Held 0", app: app); wait("TimedOut 1", app: app)
        XCTAssertFalse(app.staticTexts["catalog-session-probe"].label.contains("Drained 1"))
        XCTAssertTrue(app.staticTexts["catalog-session-quiescing"].exists)
        app.buttons["probe-session-admission"].tap(); wait("Active 0", app: app)
        app.buttons["quiesce-session"].tap(); wait("Drained 1", app: app)
        wait("TimedOut 0", app: app); wait("Active 0", app: app)
        XCTAssertEqual(app.staticTexts["catalog-session-probe"].label.components(separatedBy: " · ").first, epoch,
                       "Explicit re-drain must retain the already closed epoch")
        XCTAssertTrue(app.staticTexts["catalog-session-quiescing"].exists,
                      "Successful explicit drain still requires a fresh graph publication")
        app.buttons["probe-session-admission"].tap(); wait("Active 0", app: app)
        XCTAssertFalse(app.staticTexts["setup-error"].exists)
        XCTAssertFalse(app.images["Photo preview"].exists)
    }
    private func reveal(_ element: XCUIElement, app: XCUIApplication) { revealElement(element, app) }
    func testHeldActualViewerReadReleasesImageAndDrainsBeforeAnyFallbackPublication() {
        let app = launch(hold: "viewer")
        let choose = app.buttons["choose-folder"]
        XCTAssertTrue(choose.waitForExistence(timeout: 10)); choose.tap()
        let start = app.buttons["start-scan"]
        XCTAssertTrue(start.waitForExistence(timeout: 5)); start.tap()
        app.alerts.buttons["Start scan"].tap()
        let phase = app.staticTexts["scan-phase"]; reveal(phase, app: app)
        expectation(for: NSPredicate(format: "value == 'completed'"), evaluatedWith: phase)
        waitForExpectations(timeout: 15)
        app.buttons["navigate-Search"].tap()
        let show = app.buttons["show-photos"]; reveal(show, app: app); show.tap()
        let photo = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'search-photo-'" )).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 10)); reveal(photo, app: app); photo.tap()
        let pause = app.buttons["quiesce-viewer-session"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        // Original bytes and validation run before this held-publication gate.
        // Wait for the still-opening viewer, then pause through the production lifecycle.
        XCTAssertTrue(app.staticTexts["viewer-status"].waitForExistence(timeout: 5))
        let held = app.staticTexts["viewer-session-probe"]
        expectation(for: NSPredicate(format: "label CONTAINS 'Held 1'"), evaluatedWith: held)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(app.images["viewer-image"].exists)
        pause.tap()
        XCTAssertTrue(app.staticTexts["catalog-session-quiescing"].waitForExistence(timeout: 5))
        wait("Held 1", app: app)
        XCTAssertFalse(app.staticTexts["catalog-session-probe"].label.contains("Drained 1"))
        app.buttons["release-session-work"].tap(); wait("Drained 1", app: app); wait("Active 0", app: app)
        XCTAssertFalse(app.images["viewer-image"].exists)
        XCTAssertFalse(app.staticTexts["search-result-count"].exists)
    }
    func testHeldActualSearchReadCancelsWithoutPublishingOldSnapshot() {
        let app = launch(hold: "search")
        let navigation = app.buttons["navigate-Search"]
        XCTAssertTrue(navigation.waitForExistence(timeout: 10))
        // The real search path can query an empty initialized catalog; no fake query result.
        let probe = app.staticTexts["catalog-session-probe"]
        expectation(for: NSPredicate(format: "label CONTAINS 'Active 0'"), evaluatedWith: probe)
        waitForExpectations(timeout: 10)
        navigation.tap()
        let show = app.buttons["show-photos"]
        XCTAssertTrue(show.waitForExistence(timeout: 5)); show.tap()
        wait("Held 1", app: app)
        pauseAndDrain(app)
        XCTAssertFalse(app.staticTexts["search-result-count"].exists)
        XCTAssertFalse(app.staticTexts["search-error"].exists)
        XCTAssertFalse(app.images["viewer-image"].exists)
    }
}
