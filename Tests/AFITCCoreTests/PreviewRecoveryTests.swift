import XCTest
import ImageIO
import UniformTypeIdentifiers
import SQLite3
@testable import AFITCCore

final class PreviewRecoveryTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func jpeg(tint: CGFloat = 0.25) throws -> Data {
        let color = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8,
            bytesPerRow: 32 * 4, space: color, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: tint, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
    private func ledger(_ repository: CatalogRepository) async throws -> [Data] {
        try await repository.peopleRead { db in
            let statement = try PeopleSQL.statement(db, "SELECT payload FROM decisions ORDER BY rowid")
            defer { sqlite3_finalize(statement) }
            var values: [Data] = []
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                let count = Int(sqlite3_column_bytes(statement, 0))
                guard count > 0, let bytes = sqlite3_column_blob(statement, 0) else { throw ScanError.database }
                values.append(Data(bytes: bytes, count: count))
                status = sqlite3_step(statement)
            }
            guard status == SQLITE_DONE else { throw CatalogSchema.failure(db) }
            return values
        }
    }

    private func firstPhoto(_ repository: CatalogRepository) async throws -> PhotoIdentity {
        let photos = try await repository.photos()
        return try XCTUnwrap(photos.first)
    }

    actor Source: PhotoSource {
        let data: Data
        let revision: String?
        let readFailure: ScanError?
        var position = 0
        var reads = 0
        init(_ data: Data, revision: String?, readFailure: ScanError? = nil) {
            self.data = data; self.revision = revision; self.readFailure = readFailure
        }
        func identity() async throws -> String? { "volume:preview-recovery" }
        func open() async throws {}
        func next() async throws -> SourceEntry? {
            guard position == 0 else { return nil }
            position += 1
            return SourceEntry(relativePath: "nested/person.jpg",
                metadata: SourceMetadata(revision: revision, size: data.count))
        }
        func read(_ entry: SourceEntry) async throws -> Data {
            reads += 1
            if let readFailure { throw readFailure }
            return data
        }
        func close() async {}
        func readCount() -> Int { reads }
    }

    actor GatedSource: PhotoSource {
        let data: Data
        var position = 0
        var waiting = false
        var continuation: CheckedContinuation<Void, Never>?
        init(_ data: Data) { self.data = data }
        func identity() async throws -> String? { "volume:preview-recovery" }
        func open() async throws {}
        func next() async throws -> SourceEntry? {
            guard position == 0 else { return nil }
            position += 1
            return SourceEntry(relativePath: "nested/person.jpg",
                metadata: SourceMetadata(revision: "trusted-r1", size: data.count))
        }
        func read(_ entry: SourceEntry) async throws -> Data {
            waiting = true
            await withCheckedContinuation { continuation = $0 }
            return data
        }
        func close() async {}
        func isWaiting() -> Bool { waiting }
        func release() { continuation?.resume(); continuation = nil }
    }

    actor Detector: DetectionProvider {
        var calls = 0
        func process(_ data: Data, contentVersion: Int) async throws -> ProcessedPreview {
            calls += 1
            let image = try JPEGPreviewDecoder.decode(data)
            let preview = try JPEGPreviewDecoder.jpeg(image)
            let face = FaceGeometry(rectangle: [0.1, 0.1, 0.5, 0.5], landmarks: [])
            return ProcessedPreview(jpeg: preview, analysis: FaceAnalysisState(status: .successful,
                detectorVersion: "fixture-v1", contentVersion: contentVersion, faces: [face]))
        }
        func count() -> Int { calls }
    }

    final class PublishGate: @unchecked Sendable {
        private let lock = NSLock()
        private var failure: ScanError?
        func set(_ value: ScanError?) { lock.lock(); failure = value; lock.unlock() }
        func check() throws {
            lock.lock(); let value = failure; lock.unlock()
            if let value { throw value }
        }
    }

    func testTrustedPresentPreviewStaysReadFreeAndClearThenRebuildPreservesIdentity() async throws {
        let root = try directory(), db = root.appendingPathComponent("db"), cache = root.appendingPathComponent("cache")
        let repository = try CatalogRepository(directory: db, cacheDirectory: cache)
        let detector = Detector(), bytes = try jpeg()
        let first = await ScanCoordinator(repository: repository).scan(
            source: Source(bytes, revision: "trusted-r1"), detector: detector) { _, _ in }
        XCTAssertEqual(first.phase, .completed)
        let original = try await firstPhoto(repository)
        let face = try XCTUnwrap(original.analysis.faces.first)
        let key = FaceKey(photo: original, face: face)
        _ = try await repository.applyDecision(.name(face: key, displayName: "Ada"))
        let ledgerBefore = try await ledger(repository)
        let identityBefore = try await repository.peopleSnapshot()

        let presentSource = Source(bytes, revision: "trusted-r1")
        let present = await ScanCoordinator(repository: repository).scan(source: presentSource, detector: detector) { _, _ in }
        XCTAssertEqual(present.phase, .completed)
        let presentReads = await presentSource.readCount()
        XCTAssertEqual(presentReads, 0)
        let removed = try await repository.clearDerivedCache()
        XCTAssertEqual(removed, 1)

        let missingSource = Source(bytes, revision: "trusted-r1")
        let rebuilt = await ScanCoordinator(repository: repository).scan(source: missingSource, detector: detector) { _, _ in }
        XCTAssertEqual(rebuilt.phase, .completed)
        let missingReads = await missingSource.readCount(), detectorCalls = await detector.count()
        XCTAssertEqual(missingReads, 1)
        XCTAssertEqual(detectorCalls, 1)

        let restored = try await firstPhoto(repository)
        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.contentVersion, original.contentVersion)
        XCTAssertEqual(restored.contentHash, original.contentHash)
        XCTAssertEqual(restored.analysis, original.analysis)
        let path = try XCTUnwrap(restored.previewPath)
        let restoredJPEG = try Data(contentsOf: cache.appendingPathComponent(path))
        XCTAssertNoThrow(try JPEGPreviewDecoder.decode(restoredJPEG))
        let ledgerAfter = try await ledger(repository)
        XCTAssertEqual(ledgerAfter, ledgerBefore)
        let identityAfter = try await repository.peopleSnapshot()
        XCTAssertEqual(identityAfter.faces.first(where: { $0.key == key })?.state,
                       identityBefore.faces.first(where: { $0.key == key })?.state)
        XCTAssertEqual(identityAfter.people.map(\.confirmedPhotoCount), identityBefore.people.map(\.confirmedPhotoCount))
    }

    func testWeakUnchangedBytesRebuildWithoutDetectionAndChangedBytesUseNewGeneration() async throws {
        let root = try directory(), cache = root.appendingPathComponent("cache")
        let repository = try CatalogRepository(directory: root.appendingPathComponent("db"), cacheDirectory: cache)
        let detector = Detector(), bytes = try jpeg()
        _ = await ScanCoordinator(repository: repository).scan(source: Source(bytes, revision: nil), detector: detector) { _, _ in }
        let original = try await firstPhoto(repository)
        let beforeFaceIDs = original.analysis.faces.map(\.id)
        let removed = try await repository.clearDerivedCache()
        XCTAssertEqual(removed, 1)

        let sameSource = Source(bytes, revision: nil)
        let same = await ScanCoordinator(repository: repository).scan(source: sameSource, detector: detector) { _, _ in }
        XCTAssertEqual(same.phase, .completed)
        let sameReads = await sameSource.readCount(), detectorCallsAfterSame = await detector.count()
        XCTAssertEqual(sameReads, 1)
        XCTAssertEqual(detectorCallsAfterSame, 1)
        let preserved = try await firstPhoto(repository)
        XCTAssertEqual(preserved.id, original.id)
        XCTAssertEqual(preserved.contentVersion, original.contentVersion)
        XCTAssertEqual(preserved.analysis.faces.map(\.id), beforeFaceIDs)
        XCTAssertNotNil(preserved.previewPath)
        let preservedPath = try XCTUnwrap(preserved.previewPath)
        let preservedJPEG = try Data(contentsOf: cache.appendingPathComponent(preservedPath))
        XCTAssertNoThrow(try JPEGPreviewDecoder.decode(preservedJPEG))

        let changedSource = Source(try jpeg(tint: 0.7), revision: nil)
        let changed = await ScanCoordinator(repository: repository).scan(source: changedSource, detector: detector) { _, _ in }
        XCTAssertEqual(changed.phase, .completed)
        let next = try await firstPhoto(repository)
        XCTAssertEqual(next.id, original.id)
        XCTAssertEqual(next.contentVersion, original.contentVersion + 1)
        XCTAssertNotEqual(next.analysis.faces.map(\.id), beforeFaceIDs)
        let callsAfterChange = await detector.count()
        XCTAssertEqual(callsAfterChange, 2)
    }

    func testUnavailableSourceRetainsAcceptedAnalysisAndReportsMissingPreview() async throws {
        let root = try directory(), repository = try CatalogRepository(directory: root.appendingPathComponent("db"),
            cacheDirectory: root.appendingPathComponent("cache"))
        let detector = Detector(), bytes = try jpeg()
        _ = await ScanCoordinator(repository: repository).scan(source: Source(bytes, revision: "trusted-r1"), detector: detector) { _, _ in }
        let original = try await firstPhoto(repository)
        _ = try await repository.clearDerivedCache()
        let result = await ScanCoordinator(repository: repository).scan(
            source: Source(bytes, revision: "trusted-r1", readFailure: .unavailable), detector: detector) { _, _ in }
        XCTAssertEqual(result.phase, .failed)
        XCTAssertTrue(result.message?.contains("Preview unavailable") == true)
        let retained = try await firstPhoto(repository)
        XCTAssertEqual(retained.id, original.id)
        XCTAssertEqual(retained.contentVersion, original.contentVersion)
        XCTAssertEqual(retained.analysis, original.analysis)
        XCTAssertNil(retained.previewPath)
        let detectorCalls = await detector.count()
        XCTAssertEqual(detectorCalls, 1)
    }

    func testCancellationWhileCheckingMissingPreviewKeepsAcceptedIdentity() async throws {
        let root = try directory(), repository = try CatalogRepository(directory: root.appendingPathComponent("db"),
            cacheDirectory: root.appendingPathComponent("cache"))
        let detector = Detector(), bytes = try jpeg()
        _ = await ScanCoordinator(repository: repository).scan(source: Source(bytes, revision: "trusted-r1"), detector: detector) { _, _ in }
        let original = try await firstPhoto(repository)
        _ = try await repository.clearDerivedCache()
        let scanner = ScanCoordinator(repository: repository), source = GatedSource(bytes)
        let task = Task { await scanner.scan(source: source, detector: detector) { _, _ in } }
        for _ in 0..<100 where !(await source.isWaiting()) { try await Task.sleep(nanoseconds: 10_000_000) }
        let sourceWaiting = await source.isWaiting()
        XCTAssertTrue(sourceWaiting)
        await scanner.cancel()
        await source.release()
        let result = await task.value
        XCTAssertEqual(result.phase, .cancelled)
        XCTAssertTrue(result.message?.contains("preview recovery") == true)
        let retained = try await firstPhoto(repository)
        XCTAssertEqual(retained.id, original.id)
        XCTAssertEqual(retained.contentVersion, original.contentVersion)
        XCTAssertEqual(retained.analysis, original.analysis)
        XCTAssertNil(retained.previewPath)
        let detectorCalls = await detector.count()
        XCTAssertEqual(detectorCalls, 1)
    }

    func testStoragePressureDuringRebuildLeavesAcceptedAnalysisAndDecisions() async throws {
        let root = try directory(), db = root.appendingPathComponent("db"), cache = root.appendingPathComponent("cache")
        let gate = PublishGate()
        let repository = try CatalogRepository(directory: db, cacheDirectory: cache, reservation: nil,
            beforePreviewPublish: { try gate.check() })
        let detector = Detector(), bytes = try jpeg()
        _ = await ScanCoordinator(repository: repository).scan(source: Source(bytes, revision: "trusted-r1"), detector: detector) { _, _ in }
        let original = try await firstPhoto(repository)
        let key = FaceKey(photo: original, face: try XCTUnwrap(original.analysis.faces.first))
        _ = try await repository.applyDecision(.name(face: key, displayName: "Grace"))
        let ledgerBefore = try await ledger(repository)
        let statesBefore = try await repository.peopleSnapshot()
        _ = try await repository.clearDerivedCache()

        gate.set(.storagePressure)
        let result = await ScanCoordinator(repository: repository).scan(
            source: Source(bytes, revision: "trusted-r1"), detector: detector) { _, _ in }
        XCTAssertEqual(result.phase, .paused)
        XCTAssertTrue(result.message?.contains("Preview unavailable") == true)
        let retained = try await firstPhoto(repository)
        XCTAssertEqual(retained.id, original.id)
        XCTAssertEqual(retained.contentVersion, original.contentVersion)
        XCTAssertEqual(retained.analysis, original.analysis)
        XCTAssertNil(retained.previewPath)
        let ledgerAfter = try await ledger(repository)
        XCTAssertEqual(ledgerAfter, ledgerBefore)
        let statesAfter = try await repository.peopleSnapshot()
        XCTAssertEqual(statesAfter.faces.first(where: { $0.key == key })?.state,
                       statesBefore.faces.first(where: { $0.key == key })?.state)
        let detectorCalls = await detector.count()
        XCTAssertEqual(detectorCalls, 1)
    }

    /// A missing preview must not shield an original that became unreadable from invalidation.
    private func assertMissingPreviewUnreadableChangedOriginalInvalidates(_ failure: ScanError) async throws {
        let root = try directory(), repository = try CatalogRepository(directory: root.appendingPathComponent("db"),
            cacheDirectory: root.appendingPathComponent("cache"))
        let detector = Detector(), bytes = try jpeg()
        _ = await ScanCoordinator(repository: repository).scan(source: Source(bytes, revision: "trusted-r1"), detector: detector) { _, _ in }
        let original = try await firstPhoto(repository)
        let key = FaceKey(photo: original, face: try XCTUnwrap(original.analysis.faces.first))
        _ = try await repository.applyDecision(.name(face: key, displayName: "Ada"))
        let peopleBefore = try await repository.peopleSnapshot()
        XCTAssertEqual(peopleBefore.people.map(\.confirmedPhotoCount), [1])
        _ = try await repository.clearDerivedCache()

        let result = await ScanCoordinator(repository: repository).scan(
            source: Source(bytes, revision: "trusted-r1", readFailure: failure), detector: detector) { _, _ in }
        XCTAssertEqual(result.phase, .completed)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.failed, 0)
        XCTAssertFalse(result.message?.contains("Accepted analysis remains") == true)
        XCTAssertFalse(result.message?.contains("accepted analysis is unchanged") == true)
        let invalidated = try await firstPhoto(repository)
        XCTAssertEqual(invalidated.id, original.id)
        XCTAssertEqual(invalidated.contentVersion, original.contentVersion + 1)
        XCTAssertEqual(invalidated.analysis.status, .skipped)
        XCTAssertEqual(invalidated.analysis.contentVersion, invalidated.contentVersion)
        XCTAssertTrue(invalidated.analysis.faces.isEmpty)
        XCTAssertNil(invalidated.contentHash)
        XCTAssertNil(invalidated.previewPath)
        let peopleAfter = try await repository.peopleSnapshot()
        XCTAssertEqual(peopleAfter.people.map(\.confirmedPhotoCount), [0])
        let detectorCalls = await detector.count()
        XCTAssertEqual(detectorCalls, 1)
    }

    func testMissingPreviewWithOversizedChangedOriginalInvalidatesAcceptedFaces() async throws {
        try await assertMissingPreviewUnreadableChangedOriginalInvalidates(.oversized)
    }

    func testMissingPreviewWithUnsafePathChangedOriginalInvalidatesAcceptedFaces() async throws {
        try await assertMissingPreviewUnreadableChangedOriginalInvalidates(.unsafePath)
    }
}
