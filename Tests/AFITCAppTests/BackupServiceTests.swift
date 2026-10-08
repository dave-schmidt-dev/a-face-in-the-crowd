import Foundation
import XCTest
@testable import AFITCApp
import AFITCCore

/// Portable ports over the actual AppServices owner and generated, isolated storage.
final class BackupServiceTests: XCTestCase {
    #if DEBUG
    private enum WaitFailure: Error { case timedOut }

    @MainActor private func wait(_ what: String, timeout: TimeInterval = 10,
                                file: StaticString = #filePath, line: UInt = #line,
                                _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for " + what, file: file, line: line)
                throw WaitFailure.timedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor private func fixture(_ flags: [String] = []) async throws -> (AppServices, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let arguments = ["--uitest-synthetic-source", "--uitest-synthetic-detector", "--uitest-session-controls"] + flags
        let services = AppServices(launch: LaunchOptions(arguments: arguments, ownedRoot: root))
        addTeardownBlock { try await self.retire(services, root: root) }
        try await wait("catalog startup") { services.privacyContext() != nil && services.backup.canBegin && services.hasLoadedPeopleSnapshot }
        return (services, root)
    }

    @MainActor private func retire(_ services: AppServices, root: URL) async throws {
        let backup = services.backup
        backup.cancelForProtection()
        // Releasing repeatedly also covers a consumer reaching its real hold during cancellation.
        try await wait("actual backup completion") { backup.releaseTestWork(); return !backup.busy }
        await backup.finishProtectedWork()
        try await backup.finishPrivacyDrain()
        try backup.releaseDeletedCatalogContext()
        await services.privacy.finishProtectedWork()
        await services.presentation.finishProtectedWork()
        _ = await services.diagnostics.pauseForProtectedData()
        let drained = await services.quiesceCatalogSession()
        XCTAssertTrue(drained); guard drained else { throw WaitFailure.timedOut }
        // Use the established suspension/reopen capability to close the original and release
        // its reservation; the replacement leaves scope before owned files are removed.
        if let repository = services.privacyContext()?.0 {
            let suspension = try await CatalogSuspensionRepository.beginSuspension(catalog: repository)
            try await suspension.suspend()
            _ = try await suspension.reopen()
        }
        services.releaseProtectedGraph()
        try FileManager.default.removeItem(at: root)
    }

    @MainActor func testProgressCoalescesWithoutPerRowTasksAndKeepsTerminalOutcome() async throws {
        let (services, _) = try await fixture(["--uitest-backup-hold-progress"])
        let backup = services.backup
        backup.prepareExport()
        try await wait("held progress") { backup.testStatus.contains("Held 1") }
        try await wait("one active operation") { backup.probe.contains("Active 1") }
        backup.releaseTestWork()
        try await wait("export preview") { backup.state == .exportPreview }
        try await wait("no active operation") { backup.probe.contains("Active 0") }
        XCTAssertNotNil(backup.probe.range(of: "Dropped [1-9][0-9]*", options: .regularExpression))
        XCTAssertNotNil(backup.preview?.summary)
        backup.cancelPreview()
        try await wait("idle") { backup.state == .idle && !backup.busy }
    }

    @MainActor func testOwnedRootContainsSyntheticSourceFixture() async throws {
        let (services, root) = try await fixture()
        services.chooseSyntheticFixture()
        try await wait("synthetic source selection") { services.selectedFolder != nil }
        let selected = try XCTUnwrap(services.selectedFolder).standardizedFileURL
        XCTAssertTrue(selected.path.hasPrefix(root.standardizedFileURL.path + "/"), "Synthetic source escaped the injected owner root")
        let files = try FileManager.default.contentsOfDirectory(atPath: selected.appendingPathComponent("nested").path)
        XCTAssertEqual(Set(files), Set((0..<3).map { "synthetic-\($0).jpg" }))
        let paths = try XCTUnwrap(services.deletionFixtureRoots)
        XCTAssertTrue(paths.0.path.hasPrefix(root.path + "/"))
        XCTAssertTrue(paths.1.path.hasPrefix(root.path + "/"))
    }
    #else
    func testProgressCoalescesWithoutPerRowTasksAndKeepsTerminalOutcome() throws { throw XCTSkip("Synthetic hooks require DEBUG") }
    func testOwnedRootContainsSyntheticSourceFixture() throws { throw XCTSkip("Synthetic hooks require DEBUG") }
    #endif
}
