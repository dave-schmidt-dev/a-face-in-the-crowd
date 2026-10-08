import XCTest

/// Possible matches over the generated synthetic fixture with fixed fictional vectors
/// (persisted by the first ordinary scan). Proves the review workflow only; recognition is not qualified.
///
/// Fixture outcome (see `SyntheticFaceVectorProducer`): the two synthetic-0 faces are named as the
/// examples. The person named on the pure cluster-0 face ("top") is suggested once on synthetic-1;
/// the other person is suggested on synthetic-1 and synthetic-2; the synthetic-2 near tie is ambiguous.
/// Which name lands on which cluster depends on face order, so tests read it from the first card.
final class VerificationFlowTests: XCTestCase {
    private struct Card: Equatable { let name: String; let photo: String }

    override func setUpWithError() throws { continueAfterFailure = false; applyRequestedOrientation() }

    private func launch(compact: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-synthetic-source", "--uitest-synthetic-detector", "--uitest-synthetic-faces",
                               "--uitest-catalog-token", UUID().uuidString]
        if compact { app.launchArguments += ["--uitest-compact", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        return app
    }

    /// One ordinary scan saves all six faces; both synthetic-0 examples are named, then Verify opens.
    private func prepared(compact: Bool = false) -> (app: XCUIApplication, top: String, other: String) {
        let app = launch(compact: compact)
        navigate("Library", app); scan(app)
        name("Fixture A", app); name("Fixture B", app)
        navigate("Verify", app)
        let first = card(app)
        XCTAssertEqual(first.photo, "synthetic-1")
        XCTAssertTrue(["Fixture A", "Fixture B"].contains(first.name))
        return (app, first.name, first.name == "Fixture A" ? "Fixture B" : "Fixture A")
    }

    // MARK: Helpers

    private func waitUntil(_ timeout: TimeInterval = 15, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }
    private func reveal(_ element: XCUIElement, _ app: XCUIApplication) { revealElement(element, app) }
    private func revealed(_ element: XCUIElement, _ app: XCUIApplication) -> Bool { isRevealed(element, app) }
    private func tap(_ id: String, _ app: XCUIApplication) {
        let element = app.buttons[id].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 10), id)
        if app.navigationBars.buttons[id].firstMatch.exists {
            XCTAssertTrue(waitUntil { element.isHittable }, id)
            element.tap()
            return
        }
        reveal(element, app); XCTAssertTrue(revealed(element, app), id); element.tap()
    }
    private func navigate(_ title: String, _ app: XCUIApplication) {
        navigateTo(title, app)
    }
    private func label(_ id: String, contains text: String, _ app: XCUIApplication) {
        let element = app.descendants(matching: .any)[id].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 15), id)
        XCTAssertTrue(waitUntil { element.label.contains(text) }, "\(id): '\(element.label)' lacks '\(text)'")
    }
    /// The phase badge's label is human copy; its accessibility value is the raw phase key.
    private func phaseCompleted(_ app: XCUIApplication) {
        let phase = app.staticTexts["scan-phase"].firstMatch
        XCTAssertTrue(phase.waitForExistence(timeout: 15), "scan-phase")
        XCTAssertTrue(waitUntil { phase.value as? String == "completed" }, "scan-phase: '\(phase.value ?? "nil")' is not completed")
    }
    private func scan(_ app: XCUIApplication) {
        tap("choose-folder", app); tap("start-scan", app)
        XCTAssertTrue(app.alerts.buttons["Start scan"].waitForExistence(timeout: 10)); app.alerts.buttons["Start scan"].tap()
        phaseCompleted(app)
    }
    /// Names the next unidentified synthetic-0 face.
    private func name(_ value: String, _ app: XCUIApplication) {
        navigate("People", app)
        let face = app.buttons.matching(NSPredicate(format: "identifier == 'unidentified-face' AND label CONTAINS %@",
                                                    "nested/synthetic-0.jpg")).firstMatch
        reveal(face, app); XCTAssertTrue(face.waitForExistence(timeout: 10)); face.tap()
        let field = app.textFields["new-person-name"]; XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap(); field.typeText(value)
        tap("save-selected-face", app); XCTAssertTrue(field.waitForNonExistence(timeout: 10))
    }
    /// The card on screen: suggested name and the candidate's synthetic photo.
    private func card(_ app: XCUIApplication) -> Card {
        let title = app.staticTexts["review-person-name"]
        XCTAssertTrue(title.waitForExistence(timeout: 20), "no review card")
        return Card(name: title.label.replacingOccurrences(of: "Is this ", with: "").replacingOccurrences(of: "?", with: ""),
                    photo: candidatePhoto(app))
    }
    private func candidatePhoto(_ app: XCUIApplication) -> String {
        let tile = app.descendants(matching: .any)["review-candidate-face"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        return ["synthetic-0", "synthetic-1", "synthetic-2"].first { tile.label.contains($0) } ?? "unknown: " + tile.label
    }
    private func expectCard(_ expected: Card, _ app: XCUIApplication) {
        let title = app.staticTexts["review-person-name"]
        XCTAssertTrue(waitUntil {
            title.exists && title.label == "Is this \(expected.name)?" && candidatePhoto(app) == expected.photo
        }, "expected card \(expected)")
    }
    /// Taps a card answer once it is enabled (actions wait for the post-decision ranking).
    private func answer(_ id: String, _ app: XCUIApplication) {
        let button = app.buttons[id].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), id)
        XCTAssertTrue(waitUntil { button.isEnabled }, "\(id) stayed disabled")
        reveal(button, app); XCTAssertTrue(revealed(button, app), id); button.tap()
    }
    private func person(_ name: String, confirmed: Int, _ app: XCUIApplication) {
        navigate("People", app)
        let record = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'person-' AND label CONTAINS %@", name)).firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 10), name); reveal(record, app)
        XCTAssertTrue(waitUntil { record.label.contains(confirmed == 1 ? "1 confirmed photo" : "\(confirmed) confirmed photos") }, "\(name): \(record.label)")
    }
    private func unidentified(_ count: Int, _ app: XCUIApplication) {
        navigate("People", app); label("unidentified-count", contains: "\(count) unidentified faces", app)
    }
    // MARK: Tests

    func testVerifyUsesSavedAnalysisWithoutToggleOrRescan() {
        let app = launch()
        navigate("Verify", app)
        label("verify-review-heading", contains: "Review possible matches", app)
        XCTAssertTrue(app.staticTexts["verify-no-confirmed-faces"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.switches["evaluation-suggestions-toggle"].exists)
        navigate("Library", app); scan(app)
        name("Fixture A", app); name("Fixture B", app)
        navigate("Verify", app)
        XCTAssertEqual(card(app).photo, "synthetic-1")
        XCTAssertFalse(app.buttons["verify-find-face-details"].exists)
        label("verify-suggestion-count", contains: "Compared 4 · Ambiguous 1", app)
    }

    func testYesConfirmsOnlySelectedFaceAndUndoRestoresBeforeState() {
        let (app, top, other) = prepared()
        label("verify-suggestion-count", contains: "3 to review", app)
        label("verify-suggestion-count", contains: "Compared 4 · Ambiguous 1", app)
        answer("review-yes", app)
        expectCard(Card(name: other, photo: "synthetic-1"), app)
        label("verify-suggestion-count", contains: "2 to review", app)
        label("verify-suggestion-count", contains: "Compared 3 · Ambiguous 1", app)
        person(top, confirmed: 2, app); person(other, confirmed: 1, app); unidentified(3, app)
        navigate("Verify", app)
        tap("decision-undo", app)
        label("verify-suggestion-count", contains: "3 to review", app)
        label("verify-suggestion-count", contains: "Compared 4 · Ambiguous 1", app)
        person(top, confirmed: 1, app); person(other, confirmed: 1, app); unidentified(4, app)
        XCTAssertFalse(app.staticTexts["decision-error"].exists)
    }

    func testCompactLargeTextAndRelaunchRetainsSavedSuggestions() {
        let (app, top, other) = prepared(compact: true)
        for id in ["review-yes", "review-not-this-person", "review-unsure", "review-not-a-person", "review-skip"] {
            let button = app.buttons[id].firstMatch
            reveal(button, app); XCTAssertTrue(revealed(button, app), "\(id) not fully reachable at large text")
        }
        let context = app.buttons["review-whole-photo-context"].firstMatch
        reveal(context, app); XCTAssertTrue(revealed(context, app))
        answer("review-yes", app)
        expectCard(Card(name: other, photo: "synthetic-1"), app)
        app.terminate(); app.launch()
        navigate("Verify", app)
        expectCard(Card(name: other, photo: "synthetic-1"), app)
        label("verify-suggestion-count", contains: "2 to review", app)
        person(top, confirmed: 2, app)
    }
}
