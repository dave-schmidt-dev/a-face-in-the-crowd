import XCTest

/// Fictional runtime rectangles prove manual workflow only; no real face/model qualification.
final class PeopleFlowTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false; applyRequestedOrientation() }
    private func catalog(compact: Bool = false, previewMemoryWarning: Bool = false, extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-synthetic-source", "--uitest-synthetic-detector", "--uitest-synthetic-faces", "--uitest-catalog-token", UUID().uuidString]
        app.launchArguments += extraArguments
        if previewMemoryWarning { app.launchArguments += ["--uitest-face-preview-memory-warning"] }
        if compact { app.launchArguments += ["--uitest-compact", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.buttons["choose-folder"].waitForExistence(timeout: 10))
        app.buttons["choose-folder"].tap()
        XCTAssertTrue(app.buttons["start-scan"].waitForExistence(timeout: 5))
        app.buttons["start-scan"].tap(); app.alerts.buttons["Start scan"].tap()
        let phase = app.staticTexts["scan-phase"]
        reveal(phase, app: app, passive: true)
        XCTAssertTrue(phase.exists); XCTAssertTrue(inViewport(phase, app: app))
        expectation(for: NSPredicate(format: "value == 'completed'"), evaluatedWith: phase)
        waitForExpectations(timeout: 15)
        XCTAssertEqual(phase.value as? String, "completed")
        navigate("People", app: app)
        return app
    }
    private func inViewport(_ element: XCUIElement, app: XCUIApplication) -> Bool {
        guard element.exists else { return false }
        let frame = element.frame, viewport = app.windows.firstMatch.frame
        guard !frame.isEmpty, !frame.isNull, !frame.isInfinite,
              [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy({ $0.isFinite }) else { return false }
        return !frame.intersection(viewport).isEmpty
    }
    /// `passive` only needs the element in the viewport (it is read, not tapped); otherwise the
    /// shared reveal scrolls until the element is fully hittable.
    private func reveal(_ control: XCUIElement, app: XCUIApplication, passive: Bool = false) {
        guard passive else { revealElement(control, app); return }
        for _ in 0..<8 { if inViewport(control, app: app) { return }; scrollPage(app, towardEnd: true, containing: control.exists ? control.identifier : "") }
        for _ in 0..<12 { if inViewport(control, app: app) { return }; scrollPage(app, towardEnd: false, containing: control.exists ? control.identifier : "") }
    }
    private func navigate(_ title: String, app: XCUIApplication) { navigateTo(title, app) }
    private func tap(_ identifier: String, app: XCUIApplication) {
        let control = app.buttons[identifier].firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 5), identifier)
        if app.navigationBars.buttons[identifier].firstMatch.exists {
            XCTAssertTrue(waitUntilTrue(5) { control.isHittable }, identifier)
            control.tap()
            return
        }
        reveal(control, app: app)
        XCTAssertTrue(isRevealed(control, app), identifier + " " + whyNotRevealed(control, app)); control.tap()
    }
    private func person(_ name: String, app: XCUIApplication) -> XCUIElement {
        let record = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'person-' AND label CONTAINS %@", name)).firstMatch
        reveal(record, app: app)
        XCTAssertTrue(record.waitForExistence(timeout: 5)); return record
    }
    /// Walk the complete fixture-sized People section; lazy rows are not a global count.
    private func peopleRecords(app: XCUIApplication) -> [String: String] {
        let scroll = app.scrollViews["screen-People"]
        let heading = scroll.staticTexts["people-records-start"]
        let boundary = scroll.staticTexts["Individual face review"]
        reveal(heading, app: app, passive: true)
        XCTAssertTrue(inViewport(heading, app: app), "People traversal must start at its confirmed records subsection")
        guard inViewport(heading, app: app) else { return [:] }
        var records: [String: String] = [:]
        func collect() {
            for card in scroll.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'person-'" )).allElementsBoundByIndex {
                XCTAssertNotNil(UUID(uuidString: String(card.identifier.dropFirst("person-".count))))
                records[card.identifier] = card.label
            }
        }
        collect()
        for _ in 0..<8 {
            if inViewport(boundary, app: app) { break }
            dragScroll(scroll, towardEnd: true); collect()
        }
        XCTAssertTrue(inViewport(boundary, app: app), "People traversal must reach its following section")
        return records
    }
    private func personID(_ identifier: String, app: XCUIApplication) -> XCUIElement {
        let card = app.buttons[identifier]
        reveal(card, app: app)
        XCTAssertTrue(card.waitForExistence(timeout: 5)); XCTAssertTrue(isRevealed(card, app), whyNotRevealed(card, app))
        return card
    }
    private func assertPeople(_ records: [String: String], ids: Set<String>, name: String? = nil, photoCount: Int? = nil) {
        XCTAssertEqual(Set(records.keys), ids)
        for id in ids {
            guard let label = records[id] else { XCTFail("Missing person record \(id)"); continue }
            if let name { XCTAssertTrue(label.contains(name)) }
            if let photoCount { XCTAssertTrue(label.contains(photoCount == 1 ? "1 confirmed photo" : "\(photoCount) confirmed photos")) }
        }
    }
    private func mergeResultCount(app: XCUIApplication) -> Int {
        let result = app.staticTexts["merge-result-count"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        let count = result.label.split(separator: " ").compactMap { Int($0) }.first
        XCTAssertNotNil(count)
        XCTAssertTrue((1...2).contains(count ?? -1), "Two one-photo records must merge into one or two distinct photos")
        return count ?? -1
    }
    private func count(_ identifier: String, _ value: Int, app: XCUIApplication) {
        XCTAssertEqual(identifier, "unidentified-face")
        let count = app.staticTexts["unidentified-count"]
        reveal(count, app: app, passive: true)
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "label == %@", "\(value) unidentified faces"), evaluatedWith: count)
        waitForExpectations(timeout: 5)
    }
    private func name(_ value: String, app: XCUIApplication) {
        let field = app.textFields["new-person-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText(value)
        tap("save-selected-face", app: app)
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "Naming must finish dismissing its form before another face is selected")
    }
    func testSingleFaceNamingCancelDuplicateNameCorrectionAndUndo() {
        let app = catalog()
        count("unidentified-face", 6, app: app)
        tap("unidentified-face", app: app); tap("whole-photo-context", app: app)
        XCTAssertTrue(app.images["Whole photo context"].waitForExistence(timeout: 5))
        tap("cancel-face-form", app: app); count("unidentified-face", 6, app: app)
        tap("unidentified-face", app: app); name("Fixture A", app: app)
        count("unidentified-face", 5, app: app)
        let firstID = person("Fixture A", app: app).identifier
        tap("unidentified-face", app: app)
        let field = app.textFields["new-person-name"]; field.tap(); field.typeText("Fixture A")
        XCTAssertTrue(app.staticTexts["duplicate-name-warning"].exists)
        tap("save-selected-face", app: app); count("unidentified-face", 4, app: app)
        let records = peopleRecords(app: app)
        XCTAssertEqual(records.count, 2); XCTAssertTrue(records.keys.contains(firstID))
        let secondIDs = Set(records.keys).subtracting([firstID])
        XCTAssertEqual(secondIDs.count, 1)
        assertPeople(records, ids: Set([firstID]).union(secondIDs), name: "Fixture A", photoCount: 1)
        personID(firstID, app: app).tap()
        XCTAssertTrue(app.staticTexts["person-confirmed-count"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["person-confirmed-count"].label, "1 confirmed photo")
        ensureEditingPersonName(app)
        let rename = app.textFields["rename-person-name"]
        clearAndType(rename, "Fixture B", app)
        tap("save-person-name", app: app)
        XCTAssertTrue(app.staticTexts["Fixture B"].waitForExistence(timeout: 5))
        tap("correct-face", app: app); tap("unassign-face", app: app)
        expectation(for: NSPredicate(format: "label == '0 confirmed photos'"), evaluatedWith: app.staticTexts["person-confirmed-count"])
        waitForExpectations(timeout: 5)
        tap("decision-undo", app: app)
        expectation(for: NSPredicate(format: "label == '1 confirmed photo'"), evaluatedWith: app.staticTexts["person-confirmed-count"])
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.staticTexts["decision-error"].exists)
    }
    func testMemoryWarningDuringFaceDecodeRejectsStalePublication() {
        let app = catalog(previewMemoryWarning: true)
        tap("unidentified-face", app: app)
        let released = app.descendants(matching: .any)["face-preview-released"].firstMatch
        XCTAssertTrue(released.waitForExistence(timeout: 5))
        XCTAssertEqual(released.label, "Preview released to free memory")
        XCTAssertTrue(inViewport(released, app: app))
        XCTAssertFalse(app.images["Selected face crop"].exists)
        tap("whole-photo-context", app: app)
        XCTAssertTrue(released.waitForExistence(timeout: 5))
        XCTAssertFalse(app.images["Whole photo context"].exists)
        XCTAssertTrue(app.buttons["cancel-face-form"].isEnabled)
        tap("cancel-face-form", app: app)
        count("unidentified-face", 6, app: app)
    }

    func testBurstRefreshBoundsOutstandingReadsAndPublishesLatestFaces() {
        let app = catalog(extraArguments: ["--uitest-refresh-burst"])
        count("unidentified-face", 6, app: app)
        let probe = app.staticTexts["people-refresh-probe"]
        reveal(probe, app: app, passive: true)
        XCTAssertTrue(probe.waitForExistence(timeout: 5))
        XCTAssertTrue(probe.label.contains("Peak 1"))
        XCTAssertTrue(probe.label.contains("Events 36"))
        let automatic = probe.label.components(separatedBy: "Auto ").last.flatMap(Int.init)
        XCTAssertNotNil(automatic); XCTAssertLessThanOrEqual(automatic ?? 100, 12)
        XCTAssertGreaterThan(automatic ?? 0, 0)
        let reads = Int(probe.label.split(separator: " ")[1])
        XCTAssertNotNil(reads); XCTAssertLessThanOrEqual(reads ?? 100, 5)
        XCTAssertGreaterThan(reads ?? 0, 0)
    }
    func testCommittedNamingDismissesDespiteRefreshFailureAndPersistsOnce() {
        let app = catalog(extraArguments: ["--uitest-fail-people-refresh-after-decision"])
        tap("unidentified-face", app: app)
        // An empty name is invalid input: Save is disabled up front, so no error can be provoked.
        XCTAssertTrue(app.buttons["save-selected-face"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["save-selected-face"].isEnabled)
        XCTAssertTrue(app.staticTexts["name-hint"].exists)
        tap("cancel-face-form", app: app)
        XCTAssertFalse(app.staticTexts["decision-error"].exists)
        tap("unidentified-face", app: app); name("Fixture A", app: app)
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["cancel-face-form"])
        waitForExpectations(timeout: 5)
        let warning = app.staticTexts["people-refresh-warning"]
        reveal(warning, app: app, passive: true)
        XCTAssertTrue(warning.waitForExistence(timeout: 5)); XCTAssertTrue(warning.label.hasPrefix("Decision saved."))
        XCTAssertFalse(app.staticTexts["decision-error"].exists)
        app.terminate(); app.launch(); navigate("People", app: app)
        let savedID = person("Fixture A", app: app).identifier
        assertPeople(peopleRecords(app: app), ids: [savedID], name: "Fixture A", photoCount: 1)
        count("unidentified-face", 5, app: app)
        XCTAssertFalse(app.staticTexts["people-refresh-warning"].exists)
    }
    func testInitialPeopleFailurePreservesCachedLibraryCheckpointAndSource() {
        let app = catalog()
        tap("unidentified-face", app: app); name("Fixture A", app: app)
        app.terminate(); app.launchArguments += ["--uitest-fail-initial-people-read"]; app.launch()
        let preview = app.images["Photo preview"].firstMatch
        reveal(preview, app: app, passive: true); XCTAssertTrue(preview.waitForExistence(timeout: 10))
        let phase = app.staticTexts["scan-phase"]
        reveal(phase, app: app, passive: true); XCTAssertEqual(phase.value as? String, "completed")
        XCTAssertTrue(app.staticTexts["scan-counts"].label.contains("Processed 3"))
        XCTAssertEqual(app.staticTexts["source-status"].label, "Folder selected · cached previews")
        XCTAssertFalse(app.staticTexts["setup-error"].exists)
        navigate("People", app: app)
        let warning = app.staticTexts["people-refresh-warning"]
        reveal(warning, app: app, passive: true); XCTAssertTrue(warning.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["people-data-unavailable"].exists)
        XCTAssertFalse(app.staticTexts["unidentified-count"].exists)
        tap("refresh-people", app: app)
        XCTAssertTrue(person("Fixture A", app: app).exists)
        XCTAssertFalse(warning.exists)
    }
    func testUndoRenameSynchronizesEditableNameBeforeNextSave() {
        let app = catalog()
        tap("unidentified-face", app: app); name("Fixture A", app: app)
        let savedID = person("Fixture A", app: app).identifier
        personID(savedID, app: app).tap()
        ensureEditingPersonName(app)
        let field = app.textFields["rename-person-name"]
        reveal(field, app: app)
        clearAndType(field, "Fixture B", app)
        tap("save-person-name", app: app)
        ensureEditingPersonName(app)
        expectation(for: NSPredicate(format: "value == 'Fixture B'"), evaluatedWith: field); waitForExpectations(timeout: 5)
        tap("decision-undo", app: app)
        ensureEditingPersonName(app)
        expectation(for: NSPredicate(format: "value == 'Fixture A'"), evaluatedWith: field); waitForExpectations(timeout: 5)
        tap("save-person-name", app: app)
        ensureEditingPersonName(app)
        XCTAssertEqual(field.value as? String, "Fixture A")
        app.terminate(); app.launch(); navigate("People", app: app)
        let records = peopleRecords(app: app)
        assertPeople(records, ids: [savedID], name: "Fixture A", photoCount: 1)
        XCTAssertFalse(records.values.contains { $0.contains("Fixture B") })
    }
    func testLongPressPersonCardRenamesAndOffersEditActions() {
        let app = catalog()
        tap("unidentified-face", app: app); name("Fixture A", app: app)
        let card = person("Fixture A", app: app)
        let uuid = String(card.identifier.dropFirst("person-".count))
        card.press(forDuration: 1.0)
        let rename = app.buttons["person-menu-rename-" + uuid]
        let merge = app.buttons["person-menu-merge-" + uuid]
        let delete = app.buttons["person-menu-delete-" + uuid]
        XCTAssertTrue(rename.waitForExistence(timeout: 5), "Rename menu action")
        XCTAssertTrue(merge.exists, "Merge menu action")
        XCTAssertTrue(delete.exists, "Delete menu action")
        rename.tap()
        let field = app.textFields["rename-person-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Rename sheet uses the shared name editor")
        clearAndType(field, "Fixture C", app)
        tap("save-person-name", app: app)
        // The sheet takes its keyboard with it; touching the grid before both are gone races the hide key.
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "Saving dismisses the Rename sheet")
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 3)
        XCTAssertTrue(person("Fixture C", app: app).waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["decision-error"].exists)
        person("Fixture C", app: app).press(forDuration: 1.0)
        let secondDelete = app.buttons["person-menu-delete-" + uuid]
        XCTAssertTrue(secondDelete.waitForExistence(timeout: 5), "Delete menu action after rename")
        secondDelete.tap()
        let alert = app.alerts.matching(identifier: "Confirm privacy action")
        XCTAssertTrue(alert.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(alert.count, 1)
        app.alerts["Confirm privacy action"].buttons["Cancel"].tap()
    }
    func testCommittedMergeDismissesDespiteRefreshFailureAndPersistsOnce() {
        let app = catalog(extraArguments: ["--uitest-fail-people-refresh-after-merge"])
        tap("unidentified-face", app: app); name("Fixture A", app: app)
        tap("unidentified-face", app: app); name("Fixture B", app: app)
        let source = person("Fixture A", app: app), survivor = person("Fixture B", app: app)
        let sourceID = source.identifier, survivorID = survivor.identifier
        XCTAssertNotEqual(sourceID, survivorID)
        assertPeople(peopleRecords(app: app), ids: [sourceID, survivorID], photoCount: 1)
        personID(sourceID, app: app).tap(); tap("merge-person", app: app)
        tap("merge-target-" + String(survivorID.dropFirst("person-".count)), app: app)
        let combinedCount = mergeResultCount(app: app)
        tap("apply-merge", app: app)
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["cancel-merge"])
        waitForExpectations(timeout: 5)
        let warning = app.staticTexts["people-refresh-warning"]
        reveal(warning, app: app, passive: true); XCTAssertTrue(warning.waitForExistence(timeout: 5))
        XCTAssertTrue(warning.label.hasPrefix("Merge saved.")); XCTAssertFalse(app.staticTexts["decision-error"].exists)
        app.terminate(); app.launch(); navigate("People", app: app)
        let records = peopleRecords(app: app)
        assertPeople(records, ids: [survivorID], name: "Fixture B", photoCount: combinedCount)
        XCTAssertFalse(records.keys.contains(sourceID))
    }

}
