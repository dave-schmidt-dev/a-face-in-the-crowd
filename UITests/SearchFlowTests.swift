import XCTest

/// Runtime-created fictional JPEGs and manual confirmations exercise the real query and viewer.
final class SearchFlowTests: XCTestCase {
    override func setUpWithError() throws { applyRequestedOrientation() }
    private func reveal(_ element: XCUIElement, _ app: XCUIApplication) { revealElement(element, app) }
    private func tap(_ id: String, _ app: XCUIApplication) {
        let button = app.buttons[id].firstMatch; reveal(button, app)
        XCTAssertTrue(button.waitForExistence(timeout: 5)); XCTAssertTrue(isRevealed(button, app), id + " " + whyNotRevealed(button, app)); button.tap()
    }
    private func captureFailure(_ boundary: String, _ app: XCUIApplication) {
        guard app.launchArguments.contains("--uitest-synthetic-source") else { return }
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = boundary + " synthetic hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = boundary + " synthetic screen"; image.lifetime = .keepAlways; add(image)
    }
    private func navigate(_ title: String, _ app: XCUIApplication) -> Bool {
        let button = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ OR label == %@", "navigate-" + title, title)).firstMatch
        let available = button.waitForExistence(timeout: 5)
        XCTAssertTrue(available, "Navigation control must exist for " + title)
        guard available else { captureFailure("Navigate " + title, app); return false }
        button.tap()
        let reached = app.scrollViews["screen-" + title].waitForExistence(timeout: 5)
        XCTAssertTrue(reached, "Navigation must reach the " + title + " root")
        guard reached else { captureFailure("Missing " + title + " root", app); return false }
        return true
    }
    private func fixture(_ extra: [String] = []) -> XCUIApplication? {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-synthetic-source", "--uitest-synthetic-detector", "--uitest-synthetic-faces", "--uitest-catalog-token", UUID().uuidString] + extra
        app.launch(); tap("choose-folder", app); tap("start-scan", app); app.alerts.buttons["Start scan"].tap()
        let phase = app.staticTexts["scan-phase"]; reveal(phase, app)
        expectation(for: NSPredicate(format: "value == 'completed'"), evaluatedWith: phase)
        waitForExpectations(timeout: 15); XCTAssertEqual(phase.value as? String, "completed")
        guard navigate("People", app) else { return nil }; return app
    }
    private func name(_ name: String, _ app: XCUIApplication) {
        let face = app.buttons.matching(NSPredicate(format: "identifier == 'unidentified-face' AND label CONTAINS 'nested/synthetic-0.jpg'")).firstMatch
        reveal(face, app); XCTAssertTrue(face.waitForExistence(timeout: 5)); XCTAssertTrue(isRevealed(face, app), whyNotRevealed(face, app)); face.tap()
        let field = app.textFields["new-person-name"]; XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText(name); tap("save-selected-face", app)
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
    }
    private func chips(_ app: XCUIApplication, expected: Int) -> [XCUIElement]? {
        let records = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'search-person-'" )).allElementsBoundByIndex
        XCTAssertEqual(records.count, expected, "Search must show the expected active person chips")
        guard records.count == expected else { captureFailure("Unexpected Search chips", app); return nil }
        return records
    }
    private func count(_ expected: Int, _ app: XCUIApplication) {
        let label = app.staticTexts["search-result-count"]; reveal(label, app)
        XCTAssertTrue(label.waitForExistence(timeout: 5)); XCTAssertEqual(label.label, "\(expected) \(expected == 1 ? "photo" : "photos")")
    }
    func testManualConfirmationThreeModesUnknownOnlyAndOriginalView() {
        guard let app = fixture() else { return }; name("Fixture A", app)
        guard navigate("Search", app) else { return }
        XCTAssertTrue(app.staticTexts["possible-unavailable"].exists)
        guard let chip = chips(app, expected: 1) else { return }; XCTAssertNotNil(UUID(uuidString: String(chip[0].identifier.dropFirst("search-person-".count))))
        chip[0].tap(); tap("show-photos", app); count(1, app)
        let photo = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'search-photo-'" )).firstMatch
        reveal(photo, app); photo.tap()
        let status = app.staticTexts["viewer-status"]
        expectation(for: NSPredicate(format: "label BEGINSWITH 'Original'"), evaluatedWith: status); waitForExpectations(timeout: 5)
        XCTAssertTrue(app.images["viewer-image"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Synthetic original read-only viewer"; attachment.lifetime = .keepAlways; add(attachment)
        tap("close-viewer", app)
        tap("search-mode-any", app); tap("show-photos", app); count(1, app)
        tap("search-mode-only", app); tap("show-photos", app); count(0, app)
        XCTAssertTrue(app.staticTexts["search-empty"].exists)
        XCTAssertTrue(app.staticTexts["only-coverage"].label.contains("1 candidate photo withheld"))
    }
    func testEqualNamesKeepDistinctUUIDChipsAndImmutableResultCount() {
        guard let app = fixture() else { return }; name("Fixture A", app); name("Fixture A", app)
        guard navigate("Search", app) else { return }
        guard let records = chips(app, expected: 2) else { return }
        XCTAssertNotEqual(records[0].identifier, records[1].identifier)
        XCTAssertTrue(records.allSatisfy { $0.label.contains("Fixture A") })
        records[0].tap(); records[1].tap(); tap("show-photos", app)
        let frozen = app.staticTexts["search-result-count"]; XCTAssertTrue(frozen.waitForExistence(timeout: 5))
        let value = frozen.label
        XCTAssertEqual(value, "1 photo")
        XCTAssertTrue(records[0].isSelected && records[1].isSelected, "both identical-name records are selected chips")
        XCTAssertEqual(frozen.label, value)
        tap("search-mode-only", app); tap("show-photos", app)
        count(1, app)
        tap("search-mode-any", app); tap("show-photos", app); count(1, app)
    }
    func testExplicitMergeLeavesOneActiveCanonicalSearchChipAndDeduplicatedPhoto() {
        guard let app = fixture() else { return }; name("Fixture A", app); name("Fixture B", app)
        let source = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'person-' AND label CONTAINS 'Fixture A'")).firstMatch
        let survivor = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'person-' AND label CONTAINS 'Fixture B'")).firstMatch
        reveal(source, app); XCTAssertTrue(source.waitForExistence(timeout: 5))
        reveal(survivor, app); XCTAssertTrue(survivor.waitForExistence(timeout: 5))
        let sourceID = String(source.identifier.dropFirst("person-".count))
        let survivorID = String(survivor.identifier.dropFirst("person-".count))
        XCTAssertNotEqual(sourceID, survivorID)
        reveal(source, app); source.tap(); tap("merge-person", app); tap("merge-target-" + survivorID, app)
        let combined = app.staticTexts["merge-result-count"]
        XCTAssertTrue(combined.waitForExistence(timeout: 5)); XCTAssertEqual(combined.label, "After selected resolutions: 1 confirmed photo")
        tap("apply-merge", app)
        XCTAssertTrue(app.buttons["cancel-merge"].waitForNonExistence(timeout: 5))
        guard navigate("Search", app) else { return }
        guard let records = chips(app, expected: 1) else { return }
        XCTAssertEqual(records[0].identifier, "search-person-" + survivorID)
        XCTAssertTrue(records[0].label.contains("Fixture B")); XCTAssertFalse(records[0].label.contains("Fixture A"))
        records[0].tap(); tap("show-photos", app); count(1, app)
        XCTAssertTrue(records[0].isSelected); XCTAssertFalse(app.staticTexts["search-snapshot"].exists)
        tap("search-mode-only", app); tap("show-photos", app); count(1, app)
    }
    func testCompactSwitchFromNonmergedPersonReachesCanonicalSearchRoot() {
        guard let app = fixture(["--uitest-compact"]) else { return }; name("Fixture A", app)
        let person = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'person-' AND label CONTAINS 'Fixture A'")).firstMatch
        reveal(person, app); XCTAssertTrue(person.waitForExistence(timeout: 5)); XCTAssertTrue(isRevealed(person, app), whyNotRevealed(person, app))
        let personID = String(person.identifier.dropFirst("person-".count)); XCTAssertNotNil(UUID(uuidString: personID))
        person.tap(); XCTAssertTrue(app.navigationBars["Person"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["person-confirmed-count"].label, "1 confirmed photo")
        guard navigate("Search", app) else { return }
        XCTAssertTrue(app.navigationBars["Person"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(isHittableSafely(app.scrollViews["screen-Search"], app))
        guard let records = chips(app, expected: 1) else { return }
        XCTAssertEqual(records[0].identifier, "search-person-" + personID)
        XCTAssertTrue(records[0].label.contains("Fixture A"))
        records[0].tap(); tap("show-photos", app); count(1, app)
        XCTAssertTrue(records[0].isSelected); XCTAssertFalse(app.staticTexts["search-snapshot"].exists)
    }
    func testChangedOriginalHashFallsBackAndEvictedPreviewIsTruthful() {
        guard let app = fixture(["--uitest-viewer-change-bytes"]) else { return }
        guard navigate("Search", app) else { return }; tap("show-photos", app); count(3, app)
        let photo = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'search-photo-'" )).firstMatch
        reveal(photo, app); photo.tap()
        let status = app.staticTexts["viewer-status"]
        expectation(for: NSPredicate(format: "label BEGINSWITH 'Preview only'"), evaluatedWith: status); waitForExpectations(timeout: 5)
        XCTAssertTrue(app.images["viewer-image"].exists); tap("close-viewer", app); app.terminate()
        guard let evicted = fixture(["--uitest-viewer-disconnect", "--uitest-viewer-evict-preview"]) else { return }
        guard navigate("Search", evicted) else { return }; tap("show-photos", evicted); count(3, evicted)
        let item = evicted.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'search-photo-'" )).firstMatch
        reveal(item, evicted); item.tap()
        let missing = evicted.staticTexts["viewer-status"]
        expectation(for: NSPredicate(format: "label BEGINSWITH 'Preview unavailable'"), evaluatedWith: missing); waitForExpectations(timeout: 5)
        XCTAssertFalse(evicted.images["viewer-image"].exists)
    }
    func testMemoryWarningDuringOriginalDecodeReleasesBeforePublication() {
        guard let app = fixture(["--uitest-viewer-memory-warning"]) else { return }
        guard navigate("Search", app) else { return }; tap("show-photos", app); count(3, app)
        let photo = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'search-photo-'" )).firstMatch
        reveal(photo, app); photo.tap()
        let status = app.staticTexts["viewer-status"]
        expectation(for: NSPredicate(format: "label == 'Image released. Reopen to load it again.'"), evaluatedWith: status)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.images["viewer-image"].exists); tap("close-viewer", app)
    }
    func testFallbackDecodeErrorAfterMemoryReleasePreservesReleasedStatus() {
        guard let app = fixture(["--uitest-viewer-disconnect", "--uitest-viewer-fallback-error-after-release"]) else { return }
        guard navigate("Search", app) else { return }; tap("show-photos", app); count(3, app)
        let photo = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'search-photo-'" )).firstMatch
        reveal(photo, app); photo.tap()
        let status = app.staticTexts["viewer-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        let probe = app.staticTexts["viewer-request-detail-probe"]
        // Observe completion while still in the viewer, so a stale unavailable status cannot hide behind dismissal.
        expectation(for: NSPredicate(format: "label CONTAINS 'Finished 1 · Publications 0 · Late 0'"), evaluatedWith: probe)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(status.label, "Image released. Reopen to load it again.")
        XCTAssertFalse(app.images["viewer-image"].exists)
        tap("close-viewer", app)
    }
    func testCancelHeldOriginalReadNeverPublishesAfterDismiss() {
        guard let app = fixture(["--uitest-viewer-hold-read"]) else { return }
        guard navigate("Search", app) else { return }; tap("show-photos", app); count(3, app)
        let photo = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'search-photo-'" )).firstMatch
        reveal(photo, app); photo.tap()
        let status = app.staticTexts["viewer-status"]; XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.label, "Opening photo"); tap("close-viewer", app)
        let probe = app.staticTexts["viewer-request-probe"]; reveal(probe, app)
        XCTAssertTrue(probe.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "label CONTAINS 'Cancelled 1 · Finished 1'"), evaluatedWith: probe)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(probe.label.hasPrefix("Request "))
        XCTAssertTrue(probe.label.contains("Publications 0 · Late 0"), "A released request must never publish, even after dismissal")
        XCTAssertFalse(app.images["viewer-image"].exists)
        XCTAssertTrue(app.staticTexts["search-result-count"].exists)
    }
    func testDisconnectedSourceUsesCachedPreview() {
        guard let app = fixture(["--uitest-viewer-disconnect"]) else { return }
        guard navigate("Search", app) else { return }; tap("show-photos", app); count(3, app)
        let photo = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'search-photo-'" )).firstMatch
        reveal(photo, app); photo.tap()
        let status = app.staticTexts["viewer-status"]
        expectation(for: NSPredicate(format: "label BEGINSWITH 'Preview only'"), evaluatedWith: status); waitForExpectations(timeout: 5)
        XCTAssertTrue(app.images["viewer-image"].exists); tap("close-viewer", app)
        XCTAssertFalse(app.images["viewer-image"].exists)
    }
}
