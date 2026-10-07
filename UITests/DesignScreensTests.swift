import XCTest

/// Design-pass UI contract, second half: one status per screen, Settings order, Library to viewer,
/// Search layout, Verify copy and details, section path persistence, pull-to-refresh and a
/// screenshot walk. Fictional synthetic fixture only.
final class DesignScreensTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false; applyRequestedOrientation() }

    private func section(_ title: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ OR label == %@", "navigate-" + title, title)).firstMatch
    }

    private func setSuggestions(_ on: Bool, _ app: XCUIApplication) {
        navigateTo("Verify", app)
        let toggle = app.switches["evaluation-suggestions-toggle"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10)); revealElement(toggle, app)
        let wanted = on ? "1" : "0"
        if toggle.value as? String != wanted {
            let inner = toggle.switches.firstMatch
            if inner.exists { inner.tap() } else { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap() }
        }
        XCTAssertTrue(waitUntilTrue { toggle.value as? String == wanted }, "suggestions toggle did not turn \(wanted)")
    }

    // MARK: C2 status

    func testStatusAppearsOnceWithHumanPhaseCopyOnEveryScreen() {
        let app = launchFixture()
        scanFixture(app)
        for title in ["Library", "People", "Verify", "Search"] {
            navigateTo(title, app)
            XCTAssertEqual(app.staticTexts.matching(identifier: "source-status").count, 1, "\(title): status shown once")
            let phase = app.staticTexts["scan-phase"]
            XCTAssertTrue(phase.waitForExistence(timeout: 5), title)
            XCTAssertEqual(phase.label, "Scan complete", "\(title): human copy")
            XCTAssertEqual(phase.value as? String, "completed", "\(title): raw key only in the value")
            XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label IN {'Completed','completed','processing','Processing'}")).firstMatch.exists)
        }
    }

    // MARK: C5, C7 Settings

    func testSettingsPutsDestructiveActionLastAndConfirmsIt() {
        let app = launchFixture()
        tapToolbar("settings", app)
        XCTAssertTrue(app.buttons["delete-local-catalog"].waitForExistence(timeout: 10))
        let order = app.buttons.allElementsBoundByIndex.map(\.identifier)
        let delete = order.firstIndex(of: "delete-local-catalog")
        XCTAssertNotNil(delete)
        for id in ["clear-cached-previews", "disconnect-source", "prepare-backup", "choose-restore"] {
            guard let index = order.firstIndex(of: id) else { XCTFail("\(id) missing"); continue }
            XCTAssertLessThan(index, delete ?? 0, "\(id) must come before whole-catalog deletion")
        }
        let state = app.staticTexts["backup-operation-state"]
        if state.exists {
            XCTAssertFalse(["idle", "exportPreview", "restorePreview"].contains(state.label), "raw state shown: \(state.label)")
        }
        attachScreenshot("settings", app)
        tapButton("delete-local-catalog", app)
        XCTAssertTrue(app.alerts["Confirm privacy action"].waitForExistence(timeout: 10), "confirmation is unchanged")
        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["delete-local-catalog"].waitForExistence(timeout: 5), "cancel deletes nothing")
    }

    // MARK: C9, C16 Library and viewer

    func testLibraryTileOpensZoomableViewerWithoutEnumText() {
        let app = launchFixture()
        scanFixture(app); navigateTo("Library", app)
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS 'Detection:' OR label CONTAINS 'successful'")).firstMatch.exists, "no enum text")
        let tile = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'photo-'")).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 10)); revealElement(tile, app); tile.tap()
        let image = app.images["viewer-image"]
        XCTAssertTrue(image.waitForExistence(timeout: 20), "the Library tile opens the viewer")
        XCTAssertEqual(image.value as? String, "100 percent")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Date taken'")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'EXIF'")).firstMatch.exists)
        XCTAssertGreaterThan(image.frame.height, 360, "the photo uses the available space")
        attachScreenshot("photo-viewer", app)
        image.pinch(withScale: 2.5, velocity: 2)
        XCTAssertTrue(waitUntilTrue {
            Int((image.value as? String ?? "").split(separator: " ").first ?? "") ?? 100 > 100
        }, "pinch zooms: \(image.value ?? "nil")")
        image.doubleTap()
        XCTAssertTrue(waitUntilTrue { image.value as? String == "100 percent" }, "double tap resets the zoom")
        tapToolbar("close-viewer", app)
        XCTAssertTrue(app.images["viewer-image"].waitForNonExistence(timeout: 10))
    }

    // MARK: C14 Search

    func testSearchHasOneModeControlAndAPhotoGrid() {
        let app = launchFixture()
        scanFixture(app); nameFace("Fixture A", app); navigateTo("Search", app)
        let modes = ["together", "any", "only"].map { app.buttons["search-mode-\($0)"] }
        for mode in modes { XCTAssertTrue(mode.waitForExistence(timeout: 10)) }
        XCTAssertEqual(modes[0].frame.minY, modes[1].frame.minY, accuracy: 2, "modes sit in one row")
        XCTAssertEqual(modes[1].frame.minY, modes[2].frame.minY, accuracy: 2, "modes sit in one row")
        let chip = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'search-person-'")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10)); chip.tap()
        modes[1].tap(); XCTAssertTrue(modes[1].isSelected); XCTAssertFalse(modes[0].isSelected)
        let photo = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'search-photo-'")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 15))
        revealElement(photo, app)
        XCTAssertGreaterThanOrEqual(photo.frame.width, 150, "result tiles are at least about 160 pt wide")
        XCTAssertFalse(app.staticTexts["search-snapshot"].exists, "selected chips already say who was searched")
        attachScreenshot("search-results", app)
        XCTAssertFalse(app.buttons["refresh-search"].exists, "refresh-search does not exist")
        let count = app.staticTexts["search-result-count"]
        XCTAssertEqual(count.label, "1 photo")
        modes[2].tap()
        XCTAssertTrue(waitUntilTrue(15) { count.label == "0 photos" }, "tapping mode changes result count with no button press")
        XCTAssertFalse(app.buttons["refresh-search"].exists, "refresh-search does not exist")
    }

    // MARK: C15, C17 Verify

    func testVerifyOffExplanationIsAPopoverAndTimingsSitBehindDetails() {
        let app = launchFixture(extra: ["--uitest-synthetic-suggestions"])
        navigateTo("Verify", app)
        XCTAssertEqual(app.staticTexts["verify-off"].label, "Suggestions are off.")
        XCTAssertFalse(app.staticTexts["verify-off-detail"].exists, "the long text is not inline")
        tapButton("verify-explain", app)
        XCTAssertTrue(app.staticTexts["verify-off-detail"].waitForExistence(timeout: 5))
        app.staticTexts["verify-off-detail"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -6)).tap()
        XCTAssertTrue(app.staticTexts["verify-off-detail"].waitForNonExistence(timeout: 5))
        setSuggestions(true, app)
        navigateTo("Library", app); scanFixture(app)
        nameFace("Fixture A", app); navigateTo("Verify", app)
        let details = app.descendants(matching: .any)["verify-details"].firstMatch
        XCTAssertTrue(details.waitForExistence(timeout: 15))
        // The identifier of content inside a DisclosureGroup is not reliably surfaced; the copy is the contract.
        let stats = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'faces in memory'")).firstMatch
        XCTAssertFalse(stats.exists, "timings stay collapsed")
        let toggle = app.buttons["Details"].firstMatch
        revealElement(toggle.exists ? toggle : details, app)
        (toggle.exists ? toggle : details).tap()
        XCTAssertTrue(stats.waitForExistence(timeout: 5), "Details reveals the timings")
        XCTAssertTrue(stats.label.contains("photos indexed"), stats.label)
    }

    func testIndexFullNamesNextActionAndClearingRemovesIt() {
        let app = launchFixture(extra: ["--uitest-synthetic-suggestions", "--uitest-suggestion-index-capacity", "3"])
        setSuggestions(true, app)
        navigateTo("Library", app); scanFixture(app)
        nameFace("Fixture A", app); navigateTo("Verify", app)
        let full = app.staticTexts["verify-index-full"]
        XCTAssertTrue(full.waitForExistence(timeout: 20), "the full index is shown")
        XCTAssertEqual(full.label, "Suggestion index is full")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Clear face details to make room'")).firstMatch.exists,
                      "the next action is named")
        attachScreenshot("verify-index-full", app)
        tapButton("verify-index-full-clear", app)
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Clear face details' AND identifier != 'verify-index-full-clear' AND identifier != 'verify-clear-face-details'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        XCTAssertTrue(full.waitForNonExistence(timeout: 10), "clearing makes room")
    }

    // MARK: C13 path persistence

    private func pathSurvivesSectionSwitch(_ layout: Layout) {
        let app = launchFixture(layout)
        scanFixture(app); nameFace("Fixture A", app); openFirstPerson(app)
        section("Library", app).tap()
        XCTAssertTrue(app.scrollViews["screen-Library"].waitForExistence(timeout: 10))
        section("People", app).tap()
        XCTAssertTrue(app.staticTexts["person-confirmed-count"].waitForExistence(timeout: 10), "the open Person survives a section switch")
        section("People", app).tap()
        XCTAssertTrue(app.scrollViews["screen-People"].waitForExistence(timeout: 10), "selecting the section again pops to its root")
        XCTAssertFalse(app.staticTexts["person-confirmed-count"].exists)
    }

    func testOpenPersonSurvivesSectionSwitchAtRegularWidth() { pathSurvivesSectionSwitch(.regular) }
    func testOpenPersonSurvivesSectionSwitchAtCompactWidth() { pathSurvivesSectionSwitch(.compact) }

    // MARK: C18 pull to refresh

    func testPullToRefreshReloadsPeopleWithoutAButton() {
        let app = launchFixture(extra: ["--uitest-refresh-burst"])
        scanFixture(app); navigateTo("People", app)
        XCTAssertFalse(app.buttons["refresh-people"].exists, "no standing Refresh button")
        let probe = app.staticTexts["people-refresh-probe"]
        XCTAssertTrue(probe.waitForExistence(timeout: 10))
        func reads() -> Int { Int(probe.label.split(separator: " ").dropFirst().first ?? "") ?? -1 }
        var last = reads(), stable = 0
        _ = waitUntilTrue(30) {
            let now = reads(); stable = now == last ? stable + 1 : 0; last = now; return stable >= 8
        }
        let before = reads()
        let screen = app.scrollViews["screen-People"]
        for _ in 0..<3 { screen.swipeDown() }
        // Start well inside the content: a drag from the very top of a window can move the window.
        screen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            .press(forDuration: 0.1, thenDragTo: screen.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
        XCTAssertTrue(waitUntilTrue(15) { reads() > before }, "pull-to-refresh read People again (\(before) -> \(reads()))")
    }

    // MARK: Screenshot walk

    func testScreenshotWalk() {
        let app = launchFixture(extra: ["--uitest-synthetic-suggestions"])
        attachScreenshot("shot-welcome", app)
        setSuggestions(true, app)
        navigateTo("Library", app); scanFixture(app)
        attachScreenshot("shot-library", app)
        nameFace("Fixture A", app); nameFace("Fixture B", app)
        navigateTo("People", app); attachScreenshot("shot-people", app)
        openFirstPerson(app); attachScreenshot("shot-person-detail", app)
        navigateTo("Verify", app)
        _ = app.descendants(matching: .any)["review-card"].firstMatch.waitForExistence(timeout: 20)
        attachScreenshot("shot-verify", app)
        navigateTo("Search", app)
        let chip = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'search-person-'")).firstMatch
        if chip.waitForExistence(timeout: 10) { chip.tap(); app.buttons["search-mode-any"].tap() }
        _ = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'search-photo-'")).firstMatch.waitForExistence(timeout: 15)
        attachScreenshot("shot-search", app)
        tapToolbar("settings", app)
        _ = app.buttons["delete-local-catalog"].waitForExistence(timeout: 10)
        attachScreenshot("shot-settings", app)
    }

    func testVerifyDecisionButtonsVisibleWithoutScrolling() {
        let app = launchFixture(extra: ["--uitest-synthetic-suggestions"])
        navigateTo("Library", app); scanFixture(app)
        nameFace("Fixture A", app); nameFace("Fixture B", app)
        setSuggestions(true, app)
        let find = app.buttons["verify-find-face-details"].firstMatch
        XCTAssertTrue(find.waitForExistence(timeout: 10))
        let before = Int(find.value as? String ?? "") ?? -1
        find.tap()
        XCTAssertTrue(waitUntilTrue(30) {
            find.exists && find.isEnabled && (Int(find.value as? String ?? "") ?? -1) > before
        }, "Find face details did not complete")
        let phase = app.staticTexts["scan-phase"]
        XCTAssertTrue(phase.waitForExistence(timeout: 15))
        XCTAssertTrue(waitUntilTrue(20) { phase.value as? String == "completed" })
        let card = app.descendants(matching: .any)["review-card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        let windowFrame = app.windows.firstMatch.frame
        let decisionButtonIDs = ["review-yes", "review-not-this-person", "review-unsure", "review-not-a-person", "review-skip"]
        for id in decisionButtonIDs {
            let button = app.buttons[id].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 10), "\(id) missing")
            let frame = button.frame
            XCTAssertFalse(frame.isEmpty, "\(id) frame is empty")
            XCTAssertTrue(windowFrame.contains(frame), "\(id) frame \(frame) is not inside window \(windowFrame)")
        }
    }
}
