import XCTest

/// Shared synthetic-fixture helpers for the design-pass UI tests (DesignFlowTests and friends).
/// Everything here drives the fictional generated fixture only; no real photos are involved.
enum Layout {
    case regular, compact, compactXXXL
    var arguments: [String] {
        switch self {
        case .regular: return []
        case .compact: return ["--uitest-compact"]
        case .compactXXXL:
            return ["--uitest-compact", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
    }
}

extension XCTestCase {
    /// `AFITC_UI_ORIENTATION=landscape` (set in the xctestrun by the run script) rotates the device
    /// before the app launches; the real iPads are used in landscape. Every class calls this in setUp.
    func applyRequestedOrientation() {
        if ProcessInfo.processInfo.environment["AFITC_UI_ORIENTATION"] == "landscape" {
            XCUIDevice.shared.orientation = .landscapeLeft
        }
    }

    func launchFixture(_ layout: Layout = .regular, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-synthetic-source", "--uitest-synthetic-detector", "--uitest-synthetic-faces",
                               "--uitest-catalog-token", UUID().uuidString] + layout.arguments + extra
        app.launch()
        return app
    }

    func waitUntilTrue(_ timeout: TimeInterval = 15, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }

    /// True when the frame is finite, non-empty and (almost) inside the window. XCTest records a
    /// failure when `isHittable` is asked about an element whose hit point is off screen, so it is
    /// only ever asked after this frame check.
    func isOnScreen(_ element: XCUIElement, _ app: XCUIApplication) -> Bool {
        guard element.exists else { return false }
        let frame = element.frame
        guard !frame.isEmpty, !frame.isNull, !frame.isInfinite,
              [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy({ $0.isFinite }) else { return false }
        let window = app.windows.firstMatch.frame.insetBy(dx: -1, dy: -1)
        return window.contains(frame) || window.contains(CGPoint(x: frame.midX, y: frame.midY)) && frame.height > window.height * 0.8
    }

    /// Hittable without ever tripping the off-screen hit-point failure.
    func isHittableSafely(_ element: XCUIElement, _ app: XCUIApplication) -> Bool {
        isOnScreen(element, app) && element.isHittable
    }

    /// Fully inside its scroll view and clear of navigation and tab bars, then hittable. A control
    /// taller than the viewport only needs its centre on screen. Works at any window size.
    func isRevealed(_ element: XCUIElement, _ app: XCUIApplication) -> Bool {
        guard isOnScreen(element, app) else { return false }
        let frame = element.frame
        // A control behind the software keyboard is not reachable; revealElement puts the keyboard away.
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists, keyboard.frame.intersects(frame) { return false }
        let id = element.identifier
        // Not scrolled content (a bar item or a pinned inset): hittable is the whole question.
        guard !id.isEmpty, let viewport = app.scrollViews.containing(.any, identifier: id).allElementsBoundByIndex.last else {
            return element.isHittable
        }
        let bars = app.navigationBars.allElementsBoundByIndex + app.tabBars.allElementsBoundByIndex
        // A bar item (Done, Cancel, gear) lives inside its bar; only content scrolled under a bar is rejected.
        if bars.contains(where: { $0.frame.intersects(frame) && !$0.frame.insetBy(dx: -1, dy: -1).contains(frame) }) { return false }
        // Scrolled content under the bottom status inset is covered even when hittable: in a short
        // landscape window a tap there lands on the inset's own controls.
        if !Self.bottomInsetIDs.contains(id) {
            let inset = app.descendants(matching: .any).matching(NSPredicate(format: "identifier IN %@", Self.bottomInsetIDs)).allElementsBoundByIndex
            if let top = inset.map({ $0.frame.minY }).filter({ $0.isFinite }).min(), frame.maxY > top + 1 { return false }
        }
        if !viewport.frame.contains(frame),
           !(frame.height > viewport.frame.height * 0.8 && viewport.frame.contains(CGPoint(x: frame.midX, y: frame.midY))) {
            return false
        }
        return element.isHittable
    }

    /// Rows RootView pins in each screen's bottom safe-area inset (save status, retry, test controls).
    static let bottomInsetIDs = ["presentation-save-warning", "presentation-save-status", "retry-presentation-save",
                                 "presentation-persistence-probe", "flush-presentation-inputs",
                                 "presentation-save-fixture-probe", "block-presentation-save", "repair-presentation-save"]

    /// One-line geometry report for assertion messages: why an element was not revealed.
    func whyNotRevealed(_ element: XCUIElement, _ app: XCUIApplication) -> String {
        guard element.exists else { return "missing" }
        let bars = (app.navigationBars.allElementsBoundByIndex + app.tabBars.allElementsBoundByIndex).map { "\(Int($0.frame.minY))-\(Int($0.frame.maxY))" }
        let id = element.identifier
        let viewport = app.scrollViews.containing(.any, identifier: id).allElementsBoundByIndex.last?.frame
        return "frame=\(element.frame) viewport=\(String(describing: viewport)) hittable=\(isOnScreen(element, app) && element.isHittable) window=\(app.windows.firstMatch.frame) bars=\(bars) onScreen=\(isOnScreen(element, app))"
    }

    /// The one shared reveal: swipes (bounded, both directions) until the element is fully
    /// revealed. Lazy rows that do not exist yet are created by the scrolling.
    func revealElement(_ element: XCUIElement, _ app: XCUIApplication) {
        if !isRevealed(element, app) { dismissKeyboard(app) }
        // `identifier` queries the element, which fails for a lazy row that is not rendered yet.
        let id = element.exists ? element.identifier : ""
        for _ in 0..<12 { if isRevealed(element, app) { return }; scrollPage(app, towardEnd: true, containing: id) }
        for _ in 0..<16 { if isRevealed(element, app) { return }; scrollPage(app, towardEnd: false, containing: id) }
    }

    /// Puts the software keyboard away with its own hide key. A real iPad shows the software
    /// keyboard (a simulator with a hardware keyboard does not), and drags in a short landscape
    /// window above it do not reach controls below the fold.
    func dismissKeyboard(_ app: XCUIApplication) {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists else { return }
        let hide = keyboard.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'hide keyboard' OR identifier CONTAINS[c] 'hide keyboard' OR label CONTAINS[c] 'dismiss'")).firstMatch
        if hide.exists { hide.tap() }
        _ = keyboard.waitForNonExistence(timeout: 3)
    }

    /// Scrolls the scroll view holding `id` (else the front-most one) by a mid-screen drag. Never a
    /// swipe from a screen edge: in iPadOS 27 windowed mode a drag near the top moves the window
    /// and collapses the sidebar.
    func scrollPage(_ app: XCUIApplication, towardEnd: Bool, containing id: String = "") {
        var view: XCUIElement?
        if !id.isEmpty { view = app.scrollViews.containing(.any, identifier: id).allElementsBoundByIndex.last }
        if view == nil { view = app.scrollViews.allElementsBoundByIndex.last { $0.frame.height > 100 } }
        dragScroll(view ?? app.windows.firstMatch, towardEnd: towardEnd)
    }

    /// Drags inside the part of the view the software keyboard leaves visible (a drag that starts
    /// under the keyboard never reaches the scroll view). Scrolling also dismisses the keyboard
    /// interactively where the screen sets `scrollDismissesKeyboard`.
    func dragScroll(_ view: XCUIElement, towardEnd: Bool) {
        let frame = view.frame
        var bottom = frame.maxY
        let keyboard = XCUIApplication().keyboards.firstMatch
        if keyboard.exists, keyboard.frame.minY > frame.minY { bottom = min(bottom, keyboard.frame.minY) }
        let top = frame.minY + 40
        let span = max(bottom - top, 40)
        let origin = view.coordinate(withNormalizedOffset: .zero)
        let x = frame.width / 2
        let high = CGVector(dx: x, dy: 40 + span * 0.25), low = CGVector(dx: x, dy: 40 + span * 0.75)
        origin.withOffset(towardEnd ? low : high).press(forDuration: 0.05, thenDragTo: origin.withOffset(towardEnd ? high : low))
    }

    /// Replaces a text field's content: select all, then type. Delete-key sequences are not reliable
    /// on every iOS version.
    func clearAndType(_ field: XCUIElement, _ text: String, _ app: XCUIApplication) {
        field.tap()
        if (field.value as? String ?? "").isEmpty == false {
            field.press(forDuration: 1.0)
            let selectAll = app.menuItems["Select All"]
            if selectAll.waitForExistence(timeout: 2) { selectAll.tap() }
            else { field.tap(withNumberOfTaps: 3, numberOfTouches: 1) }
        }
        field.typeText(text)
    }

    func tapButton(_ id: String, _ app: XCUIApplication) {
        let element = app.buttons[id].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 10), id)
        revealElement(element, app); XCTAssertTrue(isRevealed(element, app), id + " " + whyNotRevealed(element, app)); element.tap()
    }

    /// A control inside the navigation bar (gear, Done): it is meant to sit under the bar, so it
    /// is tapped directly instead of being scrolled clear of it.
    func tapToolbar(_ id: String, _ app: XCUIApplication) {
        let element = app.buttons[id].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 10), id)
        XCTAssertTrue(waitUntilTrue(5) { element.isHittable }, id); element.tap()
    }

    func navigateTo(_ title: String, _ app: XCUIApplication) {
        let control = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ OR label == %@", "navigate-" + title, title)).firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 10), title); control.tap()
        if !app.scrollViews["screen-" + title].waitForExistence(timeout: 4) {
            // A section that kept a pushed screen: selecting it again pops to its root.
            control.tap()
        }
        XCTAssertTrue(app.scrollViews["screen-" + title].waitForExistence(timeout: 10), title)
    }

    /// Choose the synthetic folder, scan it and wait for the machine phase value `completed`.
    func scanFixture(_ app: XCUIApplication) {
        tapButton("choose-folder", app); tapButton("start-scan", app)
        XCTAssertTrue(app.alerts.buttons["Start scan"].waitForExistence(timeout: 10)); app.alerts.buttons["Start scan"].tap()
        let phase = app.staticTexts["scan-phase"]
        XCTAssertTrue(phase.waitForExistence(timeout: 15))
        XCTAssertTrue(waitUntilTrue(20) { phase.value as? String == "completed" }, "scan did not complete: \(phase.value ?? "nil")")
    }

    /// Names the unidentified synthetic-0 face.
    func nameFace(_ value: String, _ app: XCUIApplication) {
        navigateTo("People", app)
        let face = app.buttons.matching(NSPredicate(format: "identifier == 'unidentified-face' AND label CONTAINS %@",
                                                    "nested/synthetic-0.jpg")).firstMatch
        revealElement(face, app); XCTAssertTrue(face.waitForExistence(timeout: 10)); face.tap()
        let field = app.textFields["new-person-name"]; XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap(); field.typeText(value)
        tapButton("save-selected-face", app); XCTAssertTrue(field.waitForNonExistence(timeout: 10))
    }

    func openFirstPerson(_ app: XCUIApplication) {
        navigateTo("People", app)
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'person-'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10)); revealElement(card, app); card.tap()
        XCTAssertTrue(app.staticTexts["person-confirmed-count"].waitForExistence(timeout: 10))
    }

    func attachScreenshot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
