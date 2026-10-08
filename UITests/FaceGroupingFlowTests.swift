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


/// Opt-in physical-iPad probe. It observes only fixed status categories and may tap Finish once;
/// it never selects a source, accepts source identity, inspects photos, or mutates people decisions.
final class LiveAnalysisStatusProbeTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testLivePeopleAnalysisStatusAndFinish() throws {
        guard ProcessInfo.processInfo.environment["AFITC_LIVE_UI_PROBE"] == "1" else {
            throw XCTSkip("Set AFITC_LIVE_UI_PROBE=1 to run the live iPad probe.")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("This probe is for a physical iPad.")
        #else
        let app = XCUIApplication(bundleIdentifier: "com.zerodelta.AFITC")
        app.activate()

        let initial = Self.observe(app)
        if initial.pendingAlertCategory != "none" || initial.sourcePickerVisible {
            Self.emit("before", initial)
            Self.emit("after", Self.observe(app))
            throw XCTSkip("A pending alert or source picker was left untouched.")
        }

        navigateTo("People", app)
        let people = app.scrollViews["screen-People"]
        XCTAssertTrue(people.waitForExistence(timeout: 20), "People screen must be available in the live app")

        let before = Self.observe(app)
        Self.emit("before", before)
        if before.pendingAlertCategory != "none" || before.sourcePickerVisible {
            Self.emit("after", Self.observe(app))
            throw XCTSkip("A pending alert or source picker was left untouched.")
        }

        let observeOnly = ProcessInfo.processInfo.environment["AFITC_LIVE_UI_OBSERVE_ONLY"] == "1"
        if observeOnly {
            Self.observeExistingScan(app, timeout: 90)
        } else if before.finishExists && before.finishEnabled {
            let finish = app.buttons["finish-face-analysis"].firstMatch
            if !finish.isHittable { revealElement(finish, app) }
            if finish.exists && finish.isEnabled && finish.isHittable {
                finish.tap()
                Self.waitForSafeOutcome(app, timeout: 90)
            }
        }

        Self.emit("after", Self.observe(app))
        #endif
    }

    private static func observe(_ app: XCUIApplication) -> LiveAnalysisProbeObservation {
        let status = app.staticTexts["face-analysis-status"].firstMatch
        let finish = app.buttons["finish-face-analysis"].firstMatch
        let source = app.descendants(matching: .any).matching(identifier: "source-status").firstMatch
        let scanMessage = app.staticTexts["scan-message"].firstMatch
        let scanMessageText = scanMessage.exists ? scanMessage.label : nil
        let confirmation = app.alerts["Confirm the original source"].firstMatch.exists
            || scanMessageText == "Confirm that this is the original source folder before reconnecting. Matching folder names do not establish identity."
        let picker = app.navigationBars["Browse"].exists
            || app.navigationBars["Document Browser"].exists
            || app.otherElements["Document Browser"].exists
        let pendingAlert = app.alerts.firstMatch.exists
        let phaseElement = app.staticTexts["scan-phase"].firstMatch
        let phase = safePhase(phaseElement.exists ? phaseElement.value as? String : nil)
        let sourceSelected = source.exists && source.label == "Folder selected · cached previews"
        let counts = safeStatusCounts(status.exists ? status.label : nil)
        return LiveAnalysisProbeObservation(
            statusCounts: counts,
            finishExists: finish.exists,
            finishEnabled: finish.exists && finish.isEnabled,
            sourceSelected: sourceSelected,
            sourceConfirmationRequired: confirmation,
            sourcePickerVisible: picker,
            pendingAlertCategory: confirmation ? "source_confirmation" : (pendingAlert ? "other" : "none"),
            scanActive: app.buttons["cancel-scan"].exists,
            scanPhase: phase,
            scanMessageCategory: safeScanMessageCategory(scanMessageText),
            pauseCategory: safePauseCategory(counts),
            errorCategory: safeErrorCategory(app),
            peopleVisible: app.scrollViews["screen-People"].exists
        )
    }

    private static func safePhase(_ value: String?) -> String {
        guard let value else { return "not_visible" }
        switch value {
        case "ready", "discovering", "processing", "completed", "cancelled", "paused", "failed", "interrupted", "cancelling":
            return value
        default:
            return "not_visible"
        }
    }

    private static func safeStatusCounts(_ label: String?) -> [String: Int] {
        guard let label else { return [:] }
        let patterns: [(String, String)] = [
            ("photo: analysis failed", "analysis_failed"), ("photos: analysis failed", "analysis_failed"),
            ("photo: faces could not be matched automatically", "unmatched"),
            ("photos: faces could not be matched automatically", "unmatched"),
            ("photo paused: device is warm", "paused_thermal"), ("photos paused: device is warm", "paused_thermal"),
            ("photo paused: memory is low", "paused_memory"), ("photos paused: memory is low", "paused_memory"),
            ("photo paused: analysis is unavailable", "paused_unavailable"),
            ("photos paused: analysis is unavailable", "paused_unavailable"),
            ("photo paused: analysis is paused", "paused_other"), ("photos paused: analysis is paused", "paused_other"),
            ("photo needs analysis: device is warm", "needs_analysis_thermal"),
            ("photos need analysis: device is warm", "needs_analysis_thermal"),
            ("photo needs analysis: memory is low", "needs_analysis_memory"),
            ("photos need analysis: memory is low", "needs_analysis_memory"),
            ("photo needs analysis: analysis is unavailable", "needs_analysis_unavailable"),
            ("photos need analysis: analysis is unavailable", "needs_analysis_unavailable"),
            ("photo needs face analysis", "needs_analysis"), ("photos need face analysis", "needs_analysis"),
            ("photo: local face capacity reached", "capacity_reached"),
            ("photos: local face capacity reached", "capacity_reached"),
            ("photo: capacity is available; retry to continue", "capacity_available"),
            ("photos: capacity is available; retry to continue", "capacity_available")
        ]
        var counts: [String: Int] = [:]
        for component in label.components(separatedBy: " · ") {
            guard let (suffix, category) = patterns.first(where: { component.hasSuffix($0.0) }) else {
                counts["unrecognized_components", default: 0] += 1
                continue
            }
            let countText = String(component.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            guard let count = Int(countText), count >= 0 else {
                counts["unrecognized_components", default: 0] += 1
                continue
            }
            counts[category, default: 0] += count
        }
        return counts
    }

    private static func safeScanMessageCategory(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "none" }
        switch value {
        case "Saved face details remain incomplete. The verified photo will be analyzed on a later scan.":
            return "admitted_read_failed"
        case "Checking source integrity. Cached previews show the last verified content.":
            return "source_check"
        case "Preparing preview and detecting faces.":
            return "detecting"
        default:
            return "other"
        }
    }

    private static func safePauseCategory(_ counts: [String: Int]) -> String {
        if counts["paused_thermal"] != nil || counts["needs_analysis_thermal"] != nil { return "thermal" }
        if counts["paused_memory"] != nil || counts["needs_analysis_memory"] != nil { return "memory" }
        if counts["paused_unavailable"] != nil || counts["needs_analysis_unavailable"] != nil { return "unavailable" }
        if counts["paused_other"] != nil { return "other_paused" }
        return "none"
    }

    private static func safeErrorCategory(_ app: XCUIApplication) -> String {
        let error = app.staticTexts["setup-error"].firstMatch
        guard error.exists else { return "none" }
        switch error.label {
        case "Choose the original source folder to resume.",
             "Choose the original source folder before finishing face analysis.":
            return "source_missing"
        case "Source permission needs renewal. Choose the original folder again.",
             "Saved source permission could not be restored. Choose the original folder again. Cached photos remain available.",
             "Reconnect the original source folder. Restored permission is not reused.",
             "Reconnect the original source folder to access originals or resume indexing.":
            return "source_permission"
        case "Saved face analysis changed. Refresh People before finishing.":
            return "analysis_refresh_required"
        case "Catalog unavailable. Existing data has been preserved. Retry opening the catalog.":
            return "catalog_unavailable"
        default:
            return "other"
        }
    }

    private static func observeExistingScan(_ app: XCUIApplication, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        var nextObservation = Date().addingTimeInterval(15)
        while Date() < deadline {
            let current = observe(app)
            if current.sourceConfirmationRequired || current.sourcePickerVisible
                || current.pendingAlertCategory != "none" || !current.scanActive { return }
            if Date() >= nextObservation {
                emit("during_scan", current)
                nextObservation = Date().addingTimeInterval(15)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        emit("wait_timed_out", observe(app))
    }

    private static func waitForSafeOutcome(_ app: XCUIApplication, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        let startedAt = Date()
        var sawScan = false
        while Date() < deadline {
            let current = observe(app)
            if current.sourceConfirmationRequired || current.sourcePickerVisible || current.pendingAlertCategory != "none" { return }
            if current.scanActive { sawScan = true }
            if sawScan && !current.scanActive { return }
            let phaseStillWorking = ["discovering", "processing", "cancelling"].contains(current.scanPhase)
            if !sawScan && Date().timeIntervalSince(startedAt) >= 2 && !current.scanActive && (!current.finishExists || current.finishEnabled) && !phaseStillWorking { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        emit("wait_timed_out", observe(app))
    }

    private static func emit(_ stage: String, _ value: LiveAnalysisProbeObservation) {
        let output: [String: Any] = [
            "stage": stage,
            "statusCounts": value.statusCounts,
            "finishExists": value.finishExists,
            "finishEnabled": value.finishEnabled,
            "sourceSelected": value.sourceSelected,
            "sourceConfirmationRequired": value.sourceConfirmationRequired,
            "sourcePickerVisible": value.sourcePickerVisible,
            "pendingAlertCategory": value.pendingAlertCategory,
            "scanActive": value.scanActive,
            "scanPhase": value.scanPhase,
            "scanMessageCategory": value.scanMessageCategory,
            "pauseCategory": value.pauseCategory,
            "errorCategory": value.errorCategory,
            "peopleVisible": value.peopleVisible
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        print("AFITC_LIVE_UI_PROBE \(json)")
    }
}

private struct LiveAnalysisProbeObservation {
    let statusCounts: [String: Int]
    let finishExists: Bool
    let finishEnabled: Bool
    let sourceSelected: Bool
    let sourceConfirmationRequired: Bool
    let sourcePickerVisible: Bool
    let pendingAlertCategory: String
    let scanActive: Bool
    let scanPhase: String
    let scanMessageCategory: String
    let pauseCategory: String
    let errorCategory: String
    let peopleVisible: Bool
}
