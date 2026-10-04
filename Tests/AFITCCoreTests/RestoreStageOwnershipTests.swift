import XCTest
import Darwin
@testable import AFITCCore

final class RestoreStageOwnershipTests: XCTestCase {
    private func fixture() async throws -> (DecisionFixture, RestoreValidator, URL) {
        let f = try await DecisionFixture.make(self), root = f.root.appendingPathComponent("validation")
        return (f, try RestoreValidator(stagingDirectory: root), root)
    }
    func testHeldActualValidationFinishesBeforeQueuedRetirementRejectsLiveStage() async throws {
        let f = try await DecisionFixture.make(self), root = f.root.appendingPathComponent("validation")
        let validator = try RestoreValidator(stagingDirectory: root), backup = try await f.catalog.prepareBackup()
        let barrier = RestoreRootBarrier()
        let copying = Task.detached { try await validator.validate(package: backup.directory) { barrier.hold($0) } }
        var requests = barrier.requests.makeAsyncIterator(); _ = await requests.next()
        let attempt = AsyncStream<Void>.makeStream()
        let retiring = Task.detached { () -> Bool in
            attempt.continuation.yield(())
            do { try await validator.retireOwnedEmptyStagingRoot(); barrier.finish(); return true }
            catch { barrier.finish(); return false }
        }
        var starts = attempt.stream.makeAsyncIterator(); _ = await starts.next()
        XCTAssertFalse(barrier.finished)
        barrier.release.signal()
        let stage = try await copying.value; let retired = await retiring.value; XCTAssertFalse(retired)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.directory.path))
        try await validator.discard(stage); try await validator.retireOwnedEmptyStagingRoot()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    func testActualExportDiscardRetiresOnlyOwnedEmptyRootAndRejectsFutureValidation() async throws {
        let (f, validator, root) = try await fixture(), backup = try await f.catalog.prepareBackup()
        let stage = try await validator.validate(package: backup.directory)
        do { try await validator.retireOwnedEmptyStagingRoot(); XCTFail("Active stage retired") } catch { XCTAssertEqual(error as? BackupError, .unsafeStage) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: stage.directory.path))
        try await validator.discard(stage); try await validator.retireOwnedEmptyStagingRoot()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path)); XCTAssertTrue(FileManager.default.fileExists(atPath: backup.directory.path))
        do { _ = try await validator.validate(package: backup.directory); XCTFail("Terminal validator recreated root") } catch { XCTAssertEqual(error as? BackupError, .unsafeStage) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path)); try await validator.retireOwnedEmptyStagingRoot()
    }
    func testUnknownChildRefusesWithoutDeletionAndExplicitSameOwnerRetryAfterOwnedRepair() async throws {
        let (_, validator, root) = try await fixture(), foreign = root.appendingPathComponent("fixture-foreign")
        let bytes = Data("unchanged fixture".utf8); try bytes.write(to: foreign)
        do { try await validator.retireOwnedEmptyStagingRoot(); XCTFail("Foreign child removed") } catch { XCTAssertEqual(error as? BackupError, .unsafeStage) }
        XCTAssertEqual(try Data(contentsOf: foreign), bytes)
        try FileManager.default.removeItem(at: foreign); try await validator.retireOwnedEmptyStagingRoot()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    func testSymlinkInitializationAndReplacedRootRefuseAndPreserveForeignFiles() async throws {
        let f = try await DecisionFixture.make(self), victim = f.root.appendingPathComponent("victim"), root = f.root.appendingPathComponent("validation")
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: false)
        let file = victim.appendingPathComponent("unchanged"); let bytes = Data("untouched".utf8); try bytes.write(to: file)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: victim)
        XCTAssertThrowsError(try RestoreValidator(stagingDirectory: root)); XCTAssertEqual(try Data(contentsOf: file), bytes)
        try FileManager.default.removeItem(at: root)
        let validator = try RestoreValidator(stagingDirectory: root), moved = f.root.appendingPathComponent("original")
        try FileManager.default.moveItem(at: root, to: moved); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let foreign = root.appendingPathComponent("foreign"); try bytes.write(to: foreign)
        do { try await validator.retireOwnedEmptyStagingRoot(); XCTFail("Replacement removed") } catch { XCTAssertEqual(error as? RestoreValidationError, .unsafeEntry) }
        XCTAssertEqual(try Data(contentsOf: foreign), bytes); XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
    }
    func testRemovalAndParentSyncFailuresRetainSameRootCapability() async throws {
        for fault in [RestoreStageRootFault.beforeRemoval, .afterRemoval, .parentSync] {
            let (_, validator, root) = try await fixture()
            do { try await validator.retireOwnedEmptyStagingRoot(fault: fault); XCTFail("Fault ignored") } catch { XCTAssertEqual(error as? RestoreValidationError, .injectedFailure) }
            XCTAssertEqual(FileManager.default.fileExists(atPath: root.path), fault == .beforeRemoval)
            try await validator.retireOwnedEmptyStagingRoot(); XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        }
    }
    func testRemovedUnsyncedRootReplacementIsNotAdoptedOnRetry() async throws {
        let (_, validator, root) = try await fixture()
        do { try await validator.retireOwnedEmptyStagingRoot(fault: .afterRemoval); XCTFail("Fault ignored") } catch {}
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let foreign = root.appendingPathComponent("foreign"), bytes = Data("new directory".utf8); try bytes.write(to: foreign)
        do { try await validator.retireOwnedEmptyStagingRoot(); XCTFail("Replacement adopted") } catch { XCTAssertEqual(error as? RestoreValidationError, .unsafeEntry) }
        XCTAssertEqual(try Data(contentsOf: foreign), bytes)
    }
    func testCancellationBeforeRetirementLeavesOwnedDirectoryAndExplicitRetryCompletes() async throws {
        let (_, validator, root) = try await fixture()
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; try await validator.retireOwnedEmptyStagingRoot() }
        do { try await task.value; XCTFail("Cancellation ignored") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        try await validator.retireOwnedEmptyStagingRoot(); XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
}


private final class RestoreRootBarrier: @unchecked Sendable {
    let requests: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var held = false
    private var completed = false
    init() { let pair = AsyncStream<Void>.makeStream(); requests = pair.stream; continuation = pair.continuation }
    var finished: Bool { lock.lock(); defer { lock.unlock() }; return completed }
    func finish() { lock.lock(); completed = true; lock.unlock() }
    func hold(_ progress: RestoreValidationProgress) {
        lock.lock(); let first = !held; held = true; lock.unlock()
        if first { continuation.yield(()); precondition(release.wait(timeout: .now() + 5) == .success) }
    }
}
