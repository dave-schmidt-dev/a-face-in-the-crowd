import Foundation
import XCTest

/// Exact Task7 registration and accumulated phase contract, separate from host runner mechanics.
final class FaceGroupRunnerContractTests: XCTestCase {
    #if os(macOS)
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    private func loadManifest() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("tools/test-manifest.json"))) as? [String: Any])
    }

    /// Task 7.5's final phase7 union: every task7.* selector set, all existing phase6 selectors
    /// and the focused native group/name/reopen/Search journey, with exact runner membership.
    func testPhase7UnionCoversTask7Phase6AndFocusedJourney() throws {
        let manifest = try loadManifest()
        let tasks = try XCTUnwrap(manifest["tasks"] as? [String: [String: Any]])
        let phases = try XCTUnwrap(manifest["phases"] as? [String: [String]])
        let phase7 = try XCTUnwrap(phases["phase7"])
        let task7 = tasks.keys.filter { $0.hasPrefix("task7") }
        XCTAssertFalse(task7.isEmpty, "phase7 must union actual task7 work")
        let phase6 = try XCTUnwrap(phases["phase6"])
        let expected = Set(task7).union(phase6).union(["ui.group-journey"])
        XCTAssertTrue(Set(phase7).isSuperset(of: expected),
                      "phase7 missing: \(expected.subtracting(phase7).sorted())")
        XCTAssertTrue(phase7.allSatisfy { tasks[$0] != nil }, "phase7 references an unknown task")
        // The focused native journey is a phase-gated UI task over its own flow file.
        let journey = try XCTUnwrap(tasks["ui.group-journey"])
        let journeyTargets = try XCTUnwrap(journey["targets"] as? [String: [String: Any]])
        let ui = try XCTUnwrap(journeyTargets["UITests"])
        XCTAssertEqual(ui["type"] as? String, "ui")
        XCTAssertEqual(ui["phaseGateOnly"] as? Bool, true)
        XCTAssertEqual(ui["selectors"] as? [String],
                       ["UITests.FaceGroupingFlowTests/testGroupNameReopenAndSearchJourney"])
        XCTAssertEqual(ui["testFiles"] as? [String], ["UITests/FaceGroupingFlowTests.swift"])
        // Task 7.4's portable App-service tests run through SwiftPM only.
        let task74 = try XCTUnwrap(tasks["task7.4"])
        let task74Targets = try XCTUnwrap(task74["targets"] as? [String: [String: Any]])
        let appTests = try XCTUnwrap(task74Targets["AFITCAppTests"])
        XCTAssertEqual(appTests["type"] as? String, "unit")
        XCTAssertEqual(appTests["swiftpmOnly"] as? Bool, true)
        XCTAssertEqual(appTests["testFiles"] as? [String], ["Tests/AFITCAppTests/FaceGroupServiceTests.swift"])
        let selectors = try XCTUnwrap(appTests["selectors"] as? [String])
        XCTAssertFalse(selectors.isEmpty)
        XCTAssertTrue(selectors.allSatisfy { $0.hasPrefix("AFITCAppTests.FaceGroupServiceTests/") })
        // The portable App library and its tests are declared SwiftPM targets.
        let targets = try XCTUnwrap(manifest["targets"] as? [String: [String: Any]])
        let app = try XCTUnwrap(targets["AFITCApp"])
        XCTAssertEqual(app["type"] as? String, "library")
        XCTAssertEqual(app["swiftpmOnly"] as? Bool, true)
        let sources = try XCTUnwrap(app["sources"] as? [String])
        XCTAssertTrue(sources.contains("App/Services/FaceGroupService.swift"))
        XCTAssertTrue(sources.contains("App/AppServices.swift"))
        let appTestsTarget = try XCTUnwrap(targets["AFITCAppTests"])
        XCTAssertEqual(appTestsTarget["type"] as? String, "unit")
        XCTAssertEqual(appTestsTarget["swiftpmOnly"] as? Bool, true)
        XCTAssertEqual(Set(try XCTUnwrap(appTestsTarget["sources"] as? [String])),
                       Set(["Tests/AFITCAppTests/FaceGroupServiceTests.swift", "Tests/AFITCAppTests/FaceGroupSearchServiceTests.swift", "Tests/AFITCAppTests/BackupServiceTests.swift"]))
        let task75 = try XCTUnwrap(tasks["task7.5"])
        let target75 = try XCTUnwrap(task75["targets"] as? [String: [String: Any]])
        let searchApp = try XCTUnwrap(target75["AFITCAppTests"])
        XCTAssertEqual(searchApp["swiftpmOnly"] as? Bool, true)
        XCTAssertEqual(searchApp["testFiles"] as? [String], ["Tests/AFITCAppTests/FaceGroupSearchServiceTests.swift"])
        let searchSelectors = try XCTUnwrap(searchApp["selectors"] as? [String])
        XCTAssertEqual(searchSelectors.count, 5)
        XCTAssertTrue(searchSelectors.allSatisfy { $0.hasPrefix("AFITCAppTests.FaceGroupSearchServiceTests/") })
        XCTAssertTrue(phase7.contains("task7.5"))
    }

    #else
    func testPhase7UnionCoversTask7Phase6AndFocusedJourney() throws { throw XCTSkip("Host runner contract") }
    #endif
}
