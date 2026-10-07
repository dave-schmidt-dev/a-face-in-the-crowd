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
        chip[0].tap(); count(1, app)
        let photo = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'search-photo-'" )).firstMatch
        reveal(photo, app); photo.tap()
        let status = app.staticTexts["viewer-status"]
        expectation(for: NSPredicate(format: "label BEGINSWITH 'Original'"), evaluatedWith: status); waitForExpectations(timeout: 5)
        XCTAssertTrue(app.images["viewer-image"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Synthetic original read-only viewer"; attachment.lifetime = .keepAlways; add(attachment)
        tap("close-viewer", app)
        tap("search-mode-any", app); count(1, app)
        tap("search-mode-only", app); count(0, app)
        XCTAssertTrue(app.staticTexts["search-empty"].exists)
        XCTAssertTrue(app.staticTexts["only-coverage"].label.contains("1 candidate photo withheld"))
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
}
