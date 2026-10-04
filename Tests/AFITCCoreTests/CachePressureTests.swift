import XCTest
import Darwin
@testable import AFITCCore

private func regularFileBytes(in directory: URL) throws -> UInt64 {
    var total: UInt64 = 0
    for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
        var info = stat()
        guard Darwin.lstat(url.path, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard info.st_mode & S_IFMT == S_IFREG else { continue }
        let (next, overflow) = total.addingReportingOverflow(UInt64(info.st_size))
        guard !overflow else { throw ScanError.storagePressure }
        total = next
    }
    return total
}

private final class PhysicalPeakProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var readings: [UInt64] = []
    func record(_ bytes: UInt64) { lock.lock(); readings.append(bytes); lock.unlock() }
    func snapshot() -> [UInt64] { lock.lock(); defer { lock.unlock() }; return readings }
}

private final class StagingPathReplacement: @unchecked Sendable {
    private let lock = NSLock()
    private var replacedName: String?
    func name() -> String? { lock.lock(); defer { lock.unlock() }; return replacedName }
    func replaceCurrentStage(in directory: URL, with sentinel: Data, thenFail: Bool = true) throws {
        let stages = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".afitc-preview-stage-") && $0.lastPathComponent.hasSuffix(".tmp") }
        guard stages.count == 1 else { throw ScanError.database }
        let stage = stages[0]
        lock.lock(); replacedName = stage.lastPathComponent; lock.unlock()
        try FileManager.default.removeItem(at: stage)
        try sentinel.write(to: stage)
        if thenFail { throw ScanError.database }
    }
}

final class CachePressureTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func size(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    }
    private func bytesIn(_ directory: URL) throws -> Int {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .reduce(0) { $0 + (try size($1)) }
    }

    func testReplacementPeakCountsOldAndStagedBytesTogether() async throws {
        let root = try directory(), db = root.appendingPathComponent("db"), cache = root.appendingPathComponent("cache")
        var initial: CatalogRepository? = try CatalogRepository(directory: db, cacheDirectory: cache)
        let id = UUID()
        let oldName = try await initial!.storePreview(Data(repeating: 1, count: 4), id: id, budget: 12)
        _ = try await initial!.storePreview(Data(repeating: 2, count: 6), id: UUID(), budget: 12)
        initial = nil

        let repo = try CatalogRepository(directory: db, cacheDirectory: cache, reservation: nil, beforePreviewPublish: {
            guard try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)
                .reduce(0, { $0 + ((try FileManager.default.attributesOfItem(atPath: $1.path)[.size] as? NSNumber)?.intValue ?? 0) }) <= 12
            else { throw ScanError.storagePressure }
        })
        let newName = try await repo.storePreview(Data(repeating: 3, count: 6), id: id, budget: 12)
        XCTAssertEqual(newName, oldName)
        XCTAssertEqual(try Data(contentsOf: cache.appendingPathComponent(newName)), Data(repeating: 3, count: 6))
        XCTAssertEqual(try bytesIn(cache), 6)
    }

    func testOverBudgetReplacementPreservesOldPreview() async throws {
        let root = try directory(), cache = root.appendingPathComponent("cache")
        let repo = try CatalogRepository(directory: root.appendingPathComponent("db"), cacheDirectory: cache)
        let id = UUID(), name = try await repo.storePreview(Data(repeating: 1, count: 6), id: id, budget: 10)
        do {
            _ = try await repo.storePreview(Data(repeating: 2, count: 5), id: id, budget: 10)
            XCTFail("Replacement must reserve old and staged bytes together")
        } catch { XCTAssertEqual(error as? ScanError, .storagePressure) }
        XCTAssertEqual(try Data(contentsOf: cache.appendingPathComponent(name)), Data(repeating: 1, count: 6))
    }

    func testFailedStagedReplacementKeepsOldAndCleansItsTemporaryFile() async throws {
        let root = try directory(), db = root.appendingPathComponent("db"), cache = root.appendingPathComponent("cache")
        var initial: CatalogRepository? = try CatalogRepository(directory: db, cacheDirectory: cache)
        let id = UUID(), name = try await initial!.storePreview(Data(repeating: 4, count: 5), id: id, budget: 20)
        initial = nil
        let failing = try CatalogRepository(directory: db, cacheDirectory: cache, reservation: nil,
            beforePreviewPublish: { throw ScanError.database })
        do {
            _ = try await failing.storePreview(Data(repeating: 9, count: 7), id: id, budget: 20)
            XCTFail("Injected pre-publication failure must be returned")
        } catch { XCTAssertEqual(error as? ScanError, .database) }
        XCTAssertEqual(try Data(contentsOf: cache.appendingPathComponent(name)), Data(repeating: 4, count: 5))
        let remaining = try FileManager.default.contentsOfDirectory(atPath: cache.path)
        XCTAssertEqual(remaining, [name])
    }

    func testReopenAndOSRemovalReconcileInventoryWithoutTouchingForeignFiles() async throws {
        let root = try directory(), db = root.appendingPathComponent("db"), cache = root.appendingPathComponent("cache")
        var firstRepo: CatalogRepository? = try CatalogRepository(directory: db, cacheDirectory: cache)
        let evicted = try await firstRepo!.storePreview(Data(repeating: 1, count: 4), id: UUID(), budget: 12)
        _ = try await firstRepo!.storePreview(Data(repeating: 2, count: 4), id: UUID(), budget: 12)
        firstRepo = nil
        try FileManager.default.removeItem(at: cache.appendingPathComponent(evicted))

        let outside = root.appendingPathComponent("outside.txt")
        try Data("preserve".utf8).write(to: outside)
        let link = cache.appendingPathComponent(UUID().uuidString + ".jpg")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: outside.path)
        let foreign = cache.appendingPathComponent("notes.txt")
        try Data("foreign".utf8).write(to: foreign)

        let reopened = try CatalogRepository(directory: db, cacheDirectory: cache)
        let beforeBuild = await reopened.cacheInventoryBuilds
        XCTAssertEqual(beforeBuild, 0)
        _ = try await reopened.storePreview(Data(repeating: 3, count: 8), id: UUID(), budget: 12)
        let afterBuild = await reopened.cacheInventoryBuilds
        XCTAssertEqual(afterBuild, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
        XCTAssertEqual(try Data(contentsOf: outside), Data("preserve".utf8))
        XCTAssertEqual(try Data(contentsOf: foreign), Data("foreign".utf8))
    }

    func testClearDerivedCachePreservesCatalogAndForeignEntries() async throws {
        let root = try directory(), db = root.appendingPathComponent("db"), cache = root.appendingPathComponent("cache")
        let repo = try CatalogRepository(directory: db, cacheDirectory: cache)
        let first = try await repo.storePreview(Data([1, 2, 3]), id: UUID())
        let second = try await repo.storePreview(Data([4, 5]), id: UUID())
        let accepted = PhotoIdentity(relativePath: "accepted.jpg", previewPath: first,
            analysis: FaceAnalysisState(status: .successful))
        try await repo.save(accepted, progress: ScanProgress())
        let before = try await repo.photos(), checkpoint = try await repo.checkpoint()

        let outside = root.appendingPathComponent("outside.jpg")
        try Data([8, 9]).write(to: outside)
        let link = cache.appendingPathComponent(UUID().uuidString + ".jpg")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: outside.path)
        let foreign = cache.appendingPathComponent("keep.bin")
        try Data([7]).write(to: foreign)

        // This API has no source capability; clearing derived files cannot read originals.
        let removed = try await repo.clearDerivedCache()
        XCTAssertEqual(removed, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.appendingPathComponent(first).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.appendingPathComponent(second).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
        XCTAssertEqual(try Data(contentsOf: outside), Data([8, 9]))
        XCTAssertEqual(try Data(contentsOf: foreign), Data([7]))
        let after = try await repo.photos(), afterCheckpoint = try await repo.checkpoint()
        XCTAssertEqual(after, before)
        XCTAssertEqual(afterCheckpoint, checkpoint)
    }

    func testResidualStagingFileCountsTowardPhysicalPeak() async throws {
        let root = try directory(), db = root.appendingPathComponent("db"), cache = root.appendingPathComponent("cache")
        var setup: CatalogRepository? = try CatalogRepository(directory: db, cacheDirectory: cache)
        let firstID = UUID(), secondID = UUID()
        let first = try await setup!.storePreview(Data(repeating: 1, count: 4), id: firstID, budget: 12)
        let second = try await setup!.storePreview(Data(repeating: 2, count: 4), id: secondID, budget: 12)
        setup = nil

        let leftoverName = ".afitc-preview-stage-00000000-0000-0000-0000-000000000001.tmp"
        let leftover = Data(repeating: 0xEE, count: 4)
        try leftover.write(to: cache.appendingPathComponent(leftoverName))
        let existing = [first: Data(repeating: 1, count: 4), second: Data(repeating: 2, count: 4), leftoverName: leftover]
        let probe = PhysicalPeakProbe(), budget: UInt64 = 12
        let repo = try CatalogRepository(directory: db, cacheDirectory: cache, reservation: nil,
            beforePreviewPublish: { probe.record(try regularFileBytes(in: cache)) })
        var stored = false, refusedForPressure = false
        do {
            _ = try await repo.storePreview(Data(repeating: 3, count: 4), id: UUID(), budget: Int(budget))
            stored = true
        } catch let error as ScanError {
            refusedForPressure = error == .storagePressure
            if !refusedForPressure { XCTFail("Unexpected cache-store failure: \(error)") }
        } catch { XCTFail("Unexpected cache-store failure: \(error)") }

        let peakReadings = probe.snapshot()
        for peak in peakReadings {
            XCTAssertLessThanOrEqual(peak, budget, "Physical regular-file peak exceeded the cache budget")
        }
        let after = try regularFileBytes(in: cache)
        XCTAssertLessThanOrEqual(after, budget, "Physical regular-file bytes after store exceeded the cache budget")
        if refusedForPressure {
            for (name, bytes) in existing {
                XCTAssertEqual(try Data(contentsOf: cache.appendingPathComponent(name)), bytes,
                    "A rejected write must preserve every pre-existing file")
            }
        } else {
            XCTAssertTrue(stored, "Store must either fit the physical budget or refuse safely")
            XCTAssertEqual(peakReadings.count, 1, "A successful write must expose its staging peak")
        }

        let unsafeStageName = ".afitc-preview-stage-00000000-0000-0000-0000-000000000002.tmp"
        let outside = root.appendingPathComponent("outside-stage")
        let outsideBytes = Data("preserve symlink target".utf8)
        try outsideBytes.write(to: outside)
        let unsafeStage = cache.appendingPathComponent(unsafeStageName)
        try FileManager.default.createSymbolicLink(atPath: unsafeStage.path, withDestinationPath: outside.path)
        let namesBefore = Set(try FileManager.default.contentsOfDirectory(atPath: cache.path))
        let bytesBefore = try regularFileBytes(in: cache)
        let callbacksBefore = probe.snapshot()
        do {
            _ = try await repo.storePreview(Data(repeating: 4, count: 4), id: UUID(), budget: Int(budget))
            XCTFail("A canonical staging symlink must fail closed before cache effects")
        } catch { XCTAssertEqual(error as? ScanError, .unsafePath) }
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: cache.path)), namesBefore)
        XCTAssertEqual(try regularFileBytes(in: cache), bytesBefore)
        XCTAssertEqual(probe.snapshot(), callbacksBefore, "Unsafe staging entries must be rejected before publication callbacks")
        XCTAssertEqual(try Data(contentsOf: outside), outsideBytes)
    }

    func testCrashLeftoverPreviewStageIsUnlinkedAtReconcileAndForeignNamesStay() async throws {
        let root = try directory(), db = root.appendingPathComponent("db"), cache = root.appendingPathComponent("cache")
        var setup: CatalogRepository? = try CatalogRepository(directory: db, cacheDirectory: cache)
        let kept = try await setup!.storePreview(Data(repeating: 1, count: 4), id: UUID(), budget: 64)
        setup = nil
        let leftover = cache.appendingPathComponent(".afitc-preview-stage-" + UUID().uuidString + ".tmp")
        let lowercase = cache.appendingPathComponent(".afitc-preview-stage-" + UUID().uuidString.lowercased() + ".tmp")
        let foreign = cache.appendingPathComponent("foreign.tmp")
        for url in [leftover, lowercase, foreign] { try Data(repeating: 0xEE, count: 4).write(to: url) }
        let repo = try CatalogRepository(directory: db, cacheDirectory: cache)
        let stored = try await repo.storePreview(Data(repeating: 2, count: 4), id: UUID(), budget: 64)
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path), "Crash-left owned stage must be unlinked")
        for url in [lowercase, foreign] { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Non-canonical names are not owned") }
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: cache.path)),
                       [kept, stored, lowercase.lastPathComponent, foreign.lastPathComponent])
    }

    func testFailedCleanupLeavesReplacedStagingPathAlone() async throws {
        let root = try directory(), db = root.appendingPathComponent("db"), cache = root.appendingPathComponent("cache")
        var setup: CatalogRepository? = try CatalogRepository(directory: db, cacheDirectory: cache)
        let id = UUID(), oldBytes = Data(repeating: 4, count: 5)
        let oldName = try await setup!.storePreview(oldBytes, id: id, budget: 20)
        setup = nil

        let sentinel = Data("fixed foreign staging replacement".utf8)
        let replacement = StagingPathReplacement()
        let repo = try CatalogRepository(directory: db, cacheDirectory: cache, reservation: nil,
            beforePreviewPublish: { try replacement.replaceCurrentStage(in: cache, with: sentinel) })
        do {
            _ = try await repo.storePreview(Data(repeating: 9, count: 7), id: id, budget: 20)
            XCTFail("Injected failure after replacing the staging pathname must be returned")
        } catch { XCTAssertEqual(error as? ScanError, .database) }

        let stageName = try XCTUnwrap(replacement.name())
        let sentinelURL = cache.appendingPathComponent(stageName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinelURL.path),
            "Failure cleanup must not unlink a different file now occupying the staging pathname")
        XCTAssertEqual(try? Data(contentsOf: sentinelURL), sentinel)
        XCTAssertEqual(try Data(contentsOf: cache.appendingPathComponent(oldName)), oldBytes)
    }

    func testSubstitutedStageReturningNormallyIsNotPublished() async throws {
        let root = try directory(), db = root.appendingPathComponent("db"), cache = root.appendingPathComponent("cache")
        var setup: CatalogRepository? = try CatalogRepository(directory: db, cacheDirectory: cache)
        let id = UUID(), oldBytes = Data(repeating: 5, count: 5)
        let oldName = try await setup!.storePreview(oldBytes, id: id, budget: 20)
        setup = nil

        let sentinel = Data("fixed foreign staging replacement".utf8)
        let replacement = StagingPathReplacement()
        let repo = try CatalogRepository(directory: db, cacheDirectory: cache, reservation: nil,
            beforePreviewPublish: { try replacement.replaceCurrentStage(in: cache, with: sentinel, thenFail: false) })
        var storeError: ScanError?
        do {
            _ = try await repo.storePreview(Data(repeating: 8, count: 7), id: id, budget: 20)
            XCTFail("A substituted staging inode must not be published")
        } catch let error as ScanError { storeError = error }
        catch { XCTFail("Unexpected replacement error: \(error)") }

        XCTAssertEqual(storeError, .unsafePath)
        guard let stageName = replacement.name() else { return XCTFail("Replacement fixture did not capture its path") }
        let stageURL = cache.appendingPathComponent(stageName)
        XCTAssertEqual(try? Data(contentsOf: stageURL), sentinel,
            "The foreign replacement remains at the untrusted staging pathname")
        XCTAssertEqual(try Data(contentsOf: cache.appendingPathComponent(oldName)), oldBytes,
            "The accepted old preview must survive staging substitution")
    }
}
