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
    private func singleViewerStatus(_ app: XCUIApplication) {
        let statusIdentifier = NSPredicate(format: "identifier == %@", "viewer-status")
        let viewer = app.scrollViews.containing(statusIdentifier).allElementsBoundByIndex.last
        XCTAssertNotNil(viewer, "The viewer status must be inside its scroll view")
        guard let viewer else { return }
        let status = viewer.staticTexts.matching(statusIdentifier).firstMatch
        XCTAssertTrue(status.exists)
        XCTAssertEqual(viewer.staticTexts.matching(NSPredicate(format: "label == %@", status.label)).count, 1)
        let filename = viewer.staticTexts.matching(NSPredicate(format: "identifier == %@", "viewer-filename")).firstMatch
        XCTAssertTrue(filename.exists, "The viewer scroll view must contain its filename")
        XCTAssertEqual(viewer.staticTexts.matching(NSPredicate(format: "label == %@", filename.label)).count, 1)
    }
    private func count(_ expected: Int, _ app: XCUIApplication, confirmed: Bool = true) {
        let label = app.staticTexts["search-result-count"]; reveal(label, app)
        XCTAssertTrue(label.waitForExistence(timeout: 5)); XCTAssertEqual(label.label, "\(expected)\(confirmed ? " confirmed" : "") \(expected == 1 ? "photo" : "photos")")
    }
    func testManualConfirmationThreeModesUnknownOnlyAndOriginalView() {
        guard let app = fixture() else { return }; name("Fixture A", app)
        guard navigate("Search", app) else { return }
        XCTAssertTrue(app.staticTexts["search-membership-boundary"].exists)
        guard let chip = chips(app, expected: 1) else { return }; XCTAssertNotNil(UUID(uuidString: String(chip[0].identifier.dropFirst("search-person-".count))))
        chip[0].tap(); count(1, app)
        let photo = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'search-photo-'" )).firstMatch
        reveal(photo, app); photo.tap()
        let status = app.staticTexts["viewer-status"]
        expectation(for: NSPredicate(format: "label BEGINSWITH 'Original'"), evaluatedWith: status); waitForExpectations(timeout: 5)
        singleViewerStatus(app)
        XCTAssertTrue(app.images["viewer-image"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Synthetic original read-only viewer"; attachment.lifetime = .keepAlways; add(attachment)
        tap("close-viewer", app)
        tap("search-mode-any", app); count(1, app)
        tap("search-mode-only", app); count(0, app)
        XCTAssertTrue(app.staticTexts["search-empty"].exists)
        XCTAssertTrue(app.staticTexts["only-coverage"].label.contains("1 candidate photo withheld"))
    }

    func testPersonAndSearchReviewLinksFocusRequestedPerson() {
        guard let app = fixture() else { return }
        name("Fixture A", app); name("Fixture B", app)
        let person = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'person-' AND label CONTAINS 'Fixture B'" )).firstMatch
        reveal(person, app); XCTAssertTrue(person.waitForExistence(timeout: 10)); person.tap()
        XCTAssertTrue(app.staticTexts["person-confirmed-count"].waitForExistence(timeout: 10))
        let personPossibleCount = app.staticTexts["person-possible-count"]
        XCTAssertTrue(waitUntilTrue { personPossibleCount.exists && personPossibleCount.label.contains("possible match") })
        XCTAssertFalse(app.buttons["possible-confirm"].exists)
        XCTAssertFalse(app.buttons["possible-reject"].exists)
        tap("person-review-matches", app)
        XCTAssertTrue(app.staticTexts["verify-focused-person"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["verify-focused-person"].label, "Matches for Fixture B")
        XCTAssertEqual(app.staticTexts["review-person-name"].label, "Is this Fixture B?")
        let verifyQueue = app.descendants(matching: .any)["verify-suggestion-count"]
        XCTAssertTrue(verifyQueue.waitForExistence(timeout: 10))
        let focusedReviewCount = Int(verifyQueue.label.split(separator: " ").first ?? "") ?? -1
        XCTAssertGreaterThan(focusedReviewCount, 0)
        tap("verify-show-all-matches", app)
        XCTAssertFalse(app.staticTexts["verify-focused-person"].exists)
        XCTAssertEqual(app.staticTexts["review-person-name"].label, "Is this Fixture B?")
        let allReviewCount = Int(verifyQueue.label.split(separator: " ").first ?? "") ?? -1
        XCTAssertGreaterThan(allReviewCount, focusedReviewCount, "Show all must expand the same queue while preserving its current card")

        guard navigate("Search", app) else { return }
        let chips = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'search-person-'" )).allElementsBoundByIndex
        XCTAssertEqual(chips.count, 2)
        let target = chips.first { $0.label.contains("Fixture B") }
        XCTAssertNotNil(target); target?.tap()
        tap("search-mode-any", app)
        let possible = app.staticTexts["search-possible-count"]
        XCTAssertTrue(waitUntilTrue { possible.exists && possible.label.contains("possible") })
        tap("search-review-possible-matches", app)
        XCTAssertTrue(app.staticTexts["verify-focused-person"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["verify-focused-person"].label, "Matches for Fixture B")
        XCTAssertEqual(app.staticTexts["review-person-name"].label, "Is this Fixture B?")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'search-review-group-'" )).count, 0)
        let focusedSearchCount = Int(verifyQueue.label.split(separator: " ").first ?? "") ?? -1
        XCTAssertGreaterThan(focusedSearchCount, 0)
        tap("verify-show-all-matches", app)
        XCTAssertFalse(app.staticTexts["verify-focused-person"].exists)
        XCTAssertEqual(app.staticTexts["review-person-name"].label, "Is this Fixture B?")
        let allSearchCount = Int(verifyQueue.label.split(separator: " ").first ?? "") ?? -1
        XCTAssertGreaterThan(allSearchCount, focusedSearchCount, "Show all must expose the shared queue without moving its current card")
        attachScreenshot("verify-show-all-retains-fixture-b-card", app)
    }
    func testChangedOriginalHashFallsBackAndEvictedPreviewIsTruthful() {
        guard let app = fixture(["--uitest-viewer-change-bytes"]) else { return }
        guard navigate("Search", app) else { return }; tap("show-photos", app); count(3, app, confirmed: false)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == 'All catalog photos.'")).count, 1)
        XCTAssertFalse(app.staticTexts["search-snapshot"].exists)
        let photo = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'search-photo-'" )).firstMatch
        reveal(photo, app); photo.tap()
        let status = app.staticTexts["viewer-status"]
        expectation(for: NSPredicate(format: "label BEGINSWITH 'Preview only'"), evaluatedWith: status); waitForExpectations(timeout: 5)
        singleViewerStatus(app)
        XCTAssertTrue(app.images["viewer-image"].exists); tap("close-viewer", app); app.terminate()
        guard let evicted = fixture(["--uitest-viewer-disconnect", "--uitest-viewer-evict-preview"]) else { return }
        guard navigate("Search", evicted) else { return }; tap("show-photos", evicted); count(3, evicted, confirmed: false)
        let item = evicted.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'search-photo-'" )).firstMatch
        reveal(item, evicted); item.tap()
        let missing = evicted.staticTexts["viewer-status"]
        expectation(for: NSPredicate(format: "label BEGINSWITH 'Preview unavailable'"), evaluatedWith: missing); waitForExpectations(timeout: 5)
        singleViewerStatus(evicted)
        XCTAssertFalse(evicted.images["viewer-image"].exists)
    }
    func testMemoryWarningDuringOriginalDecodeReleasesBeforePublication() {
        guard let app = fixture(["--uitest-viewer-memory-warning"]) else { return }
        guard navigate("Search", app) else { return }; tap("show-photos", app); count(3, app, confirmed: false)
        let photo = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'search-photo-'" )).firstMatch
        reveal(photo, app); photo.tap()
        let status = app.staticTexts["viewer-status"]
        expectation(for: NSPredicate(format: "label == 'Image released. Reopen to load it again.'"), evaluatedWith: status)
        waitForExpectations(timeout: 5)
        singleViewerStatus(app)
        XCTAssertFalse(app.images["viewer-image"].exists); tap("close-viewer", app)
    }
    func testFallbackDecodeErrorAfterMemoryReleasePreservesReleasedStatus() {
        guard let app = fixture(["--uitest-viewer-disconnect", "--uitest-viewer-fallback-error-after-release"]) else { return }
        guard navigate("Search", app) else { return }; tap("show-photos", app); count(3, app, confirmed: false)
        let photo = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'search-photo-'" )).firstMatch
        reveal(photo, app); photo.tap()
        let status = app.staticTexts["viewer-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        let probe = app.staticTexts["viewer-request-detail-probe"]
        // Observe completion while still in the viewer, so a stale unavailable status cannot hide behind dismissal.
        expectation(for: NSPredicate(format: "label CONTAINS 'Finished 1 · Publications 0 · Late 0'"), evaluatedWith: probe)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(status.label, "Image released. Reopen to load it again.")
        singleViewerStatus(app)
        XCTAssertFalse(app.images["viewer-image"].exists)
        tap("close-viewer", app)
    }
    func testCancelHeldOriginalReadNeverPublishesAfterDismiss() {
        guard let app = fixture(["--uitest-viewer-hold-read"]) else { return }
        guard navigate("Search", app) else { return }; tap("show-photos", app); count(3, app, confirmed: false)
        let photo = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'search-photo-'" )).firstMatch
        reveal(photo, app); photo.tap()
        let status = app.staticTexts["viewer-status"]; XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.label, "Opening photo"); singleViewerStatus(app); tap("close-viewer", app)
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
