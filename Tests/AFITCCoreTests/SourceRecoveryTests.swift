import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import AFITCCore

final class SourceRecoveryTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    static func jpeg(width: Int = 32, height: Int = 16, orientation: Int = 1) throws -> Data {
        let color = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: color, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.25, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
    actor FixtureDetector: DetectionProvider {
        var count = 0
        func process(_ data: Data, contentVersion: Int) async throws -> ProcessedPreview {
            count += 1
            let image = try JPEGPreviewDecoder.decode(data)
            return ProcessedPreview(jpeg: try JPEGPreviewDecoder.jpeg(image), analysis: FaceAnalysisState(status: .successful, contentVersion: contentVersion))
        }
    }
    actor TraceSource: PhotoSource {
        let data: Data
        var position = 0
        var events: [String] = []
        init(data: Data) { self.data = data }
        func open() async throws { events.append("open") }
        func next() async throws -> SourceEntry? {
            events.append("next-\(position)")
            guard position < 3 else { return nil }
            defer { position += 1 }
            return SourceEntry(relativePath: "nested/\(position).jpg")
        }
        func read(_ entry: SourceEntry) async throws -> Data { events.append("read"); return data }
        func close() async { events.append("close") }
        func sawPreview() { events.append("preview") }
        func trace() -> [String] { events }
    }
    func testIncrementalPreviewBeforeEnumerationAndTruthfulCounts() async throws {
        let folder = try directory()
        let repo = try CatalogRepository(directory: folder.appendingPathComponent("db"), cacheDirectory: folder.appendingPathComponent("cache"))
        let source = TraceSource(data: try Self.jpeg())
        let scan = ScanCoordinator(repository: repo)
        let result = await scan.scan(source: source, detector: FixtureDetector()) { value, photo in
            if photo?.previewPath != nil { XCTAssertFalse(value.enumerationFinished); await source.sawPreview() }
        }
        XCTAssertEqual(result.phase, .completed)
        XCTAssertEqual(result.discovered, 3); XCTAssertEqual(result.processed, 3)
        XCTAssertEqual(result.skipped, 0); XCTAssertEqual(result.failed, 0)
        XCTAssertTrue(result.enumerationFinished)
        let trace = await source.trace()
        XCTAssertLessThan(try XCTUnwrap(trace.firstIndex(of: "preview")), try XCTUnwrap(trace.firstIndex(of: "next-1")))
        let records = try await repo.photos()
        XCTAssertEqual(Set(records.map(\.id)).count, 3)
        XCTAssertTrue(records.allSatisfy { $0.analysis.status == .successful && $0.analysis.faces.isEmpty && $0.contentVersion == $0.analysis.contentVersion })
    }
    /// Regression: a picked folder failed with "Folder access denied" on iPad because the scope was
    /// requested on a standardized copy, which can lose the security scope iOS attaches to the URL.
    func testSecurityScopeUsesTheCallersURL() {
        let picked = URL(fileURLWithPath: "/private/var/mobile/./Picked/photos", isDirectory: true)
        let source = FolderPhotoSource(root: picked)
        XCTAssertEqual(source.securityScopeURL.absoluteString, picked.absoluteString)
        XCTAssertNotEqual(source.securityScopeURL.absoluteString, picked.standardizedFileURL.absoluteString)
    }

    func testNestedReadOnlySourceDeniedUnavailableAndSymlinkEscape() async throws {
        let folder = try directory(), outside = try directory()
        let nested = folder.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let data = try Self.jpeg()
        let original = nested.appendingPathComponent("photo.jpg")
        try data.write(to: original)
        try data.write(to: outside.appendingPathComponent("outside.jpg"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("escape.jpg"), withDestinationURL: outside.appendingPathComponent("outside.jpg"))
        let source = FolderPhotoSource(root: folder, grantForTesting: true)
        try await source.open()
        var paths: Set<String> = []
        while let entry = try await source.next() {
            paths.insert(entry.relativePath)
            if entry.relativePath == "escape.jpg" {
                do { _ = try await source.read(entry); XCTFail("Symlink followed") } catch { XCTAssertEqual(error as? ScanError, .unsafePath) }
            } else { let read = try await source.read(entry); XCTAssertEqual(read, data) }
        }
        await source.close()
        XCTAssertTrue(paths.contains("nested/photo.jpg")); XCTAssertEqual(try Data(contentsOf: original), data)
        let denied = FolderPhotoSource(root: folder, grantForTesting: false)
        do { try await denied.open(); XCTFail("Denied grant accepted") } catch { XCTAssertEqual(error as? ScanError, .denied) }
        let missing = FolderPhotoSource(root: folder.appendingPathComponent("missing"), grantForTesting: true)
        do { try await missing.open(); XCTFail("Unavailable root accepted") } catch { XCTAssertEqual(error as? ScanError, .unavailable) }
        await missing.close()
    }
    func testMalformedOversizedOrientationAndDecodeBound() throws {
        XCTAssertThrowsError(try JPEGPreviewDecoder.decode(Data("not a jpeg".utf8))) { XCTAssertEqual($0 as? ScanError, .malformed) }
        XCTAssertThrowsError(try DecodeLimits.validate(bytes: 100, width: Int.max, height: 2)) { XCTAssertEqual($0 as? ScanError, .oversized) }
        XCTAssertThrowsError(try DecodeLimits.validate(bytes: DecodeLimits.maximumFileBytes + 1, width: 1, height: 1))
        let oriented = try JPEGPreviewDecoder.decode(Self.jpeg(width: 32, height: 16, orientation: 6))
        XCTAssertEqual(oriented.width, 16); XCTAssertEqual(oriented.height, 32)
        let bounded = try JPEGPreviewDecoder.decode(Self.jpeg(width: 2048, height: 16))
        XCTAssertLessThanOrEqual(max(bounded.width, bounded.height), DecodeLimits.previewDimension)
    }
    func testCancellationAndSecondScanPreserveCheckpoint() async throws {
        let folder = try directory()
        let repo = try CatalogRepository(directory: folder.appendingPathComponent("db"), cacheDirectory: folder.appendingPathComponent("cache"))
        let scan = ScanCoordinator(repository: repo)
        let result = await scan.scan(source: TraceSource(data: try Self.jpeg()), detector: FixtureDetector()) { _, photo in
            if photo?.previewPath != nil { await scan.cancel() }
        }
        XCTAssertEqual(result.phase, .cancelled); XCTAssertFalse(result.enumerationFinished)
        let saved = try await repo.photos(); XCTAssertEqual(saved.count, 1)
        let second = await scan.scan(source: TraceSource(data: try Self.jpeg()), detector: FixtureDetector(), confirmedSource: true) { _, _ in }
        XCTAssertEqual(second.phase, .completed)
        let after = try await repo.photos(); XCTAssertEqual(after.first?.id, saved.first?.id)
        XCTAssertEqual(after.count, 3)
        let checkpoint = try await repo.checkpoint(); XCTAssertEqual(checkpoint?.phase, .completed)
    }
    func testMalformedIsSkippedAndDevicePressurePauses() async throws {
        let folder = try directory()
        let repo = try CatalogRepository(directory: folder.appendingPathComponent("db"), cacheDirectory: folder.appendingPathComponent("cache"))
        let scan = ScanCoordinator(repository: repo)
        let result = await scan.scan(source: TraceSource(data: Data([0, 1, 2])), detector: FixtureDetector()) { value, photo in
            if photo != nil, value.skipped == 1 { await scan.pause() }
        }
        XCTAssertEqual(result.phase, .paused); XCTAssertEqual(result.discovered, 1); XCTAssertEqual(result.skipped, 1)
        let records = try await repo.photos()
        XCTAssertEqual(records.first?.analysis.status, .skipped); XCTAssertNil(records.first?.previewPath)
    }
    func testNativeVisionZeroFaceIndexIsSuccessfulWithoutIdentityClaim() async throws {
        let result = try await VisionJPEGDetector().process(Self.jpeg(), contentVersion: 7)
        XCTAssertEqual(result.analysis.status, .successful)
        XCTAssertEqual(result.analysis.contentVersion, 7)
        XCTAssertTrue(result.analysis.faces.isEmpty)
        XCTAssertEqual(result.analysis.detectorVersion, "vision-landmarks-r3-preview1024-v1")
        XCTAssertFalse(result.jpeg.isEmpty)
    }

    func testOversizedJPEGHeaderIsSkippedByInitialScan() async throws {
        var bytes = [UInt8](try Self.jpeg())
        let frame = try XCTUnwrap((0..<(bytes.count - 9)).first { bytes[$0] == 0xff && [0xc0, 0xc1, 0xc2].contains(bytes[$0 + 1]) })
        // Programmatic JPEG fixture: mutate dimensions, retaining its real encoded structure.
        bytes[frame + 5] = 0xff; bytes[frame + 6] = 0xff
        bytes[frame + 7] = 0xff; bytes[frame + 8] = 0xff
        let data = Data(bytes)
        XCTAssertThrowsError(try JPEGPreviewDecoder.decode(data)) { XCTAssertEqual($0 as? ScanError, .oversized) }
        let folder = try directory()
        let repo = try CatalogRepository(directory: folder.appendingPathComponent("db"), cacheDirectory: folder.appendingPathComponent("cache"))
        let result = await ScanCoordinator(repository: repo).scan(source: TraceSource(data: data), detector: FixtureDetector()) { _, _ in }
        XCTAssertEqual(result.phase, .completed); XCTAssertEqual(result.skipped, 3)
        XCTAssertEqual(result.processed, 0); XCTAssertEqual(result.failed, 0)
        let records = try await repo.photos()
        XCTAssertTrue(records.allSatisfy { $0.analysis.status == .skipped && $0.analysis.contentVersion == $0.contentVersion })
    }
    func testDeniedAndUnavailableScansDoNotPersistEmptyCatalog() async throws {
        let folder = try directory()
        let repo = try CatalogRepository(directory: folder.appendingPathComponent("db"), cacheDirectory: folder.appendingPathComponent("cache"))
        let scanner = ScanCoordinator(repository: repo)
        for denied in [true, false] {
            let source = FolderPhotoSource(root: folder.appendingPathComponent("missing"), grantForTesting: !denied)
            let result = await scanner.scan(source: source, detector: FixtureDetector()) { _, _ in }
            XCTAssertEqual(result.phase, .failed); XCTAssertFalse(result.enumerationFinished)
            XCTAssertEqual(result.message, (denied ? ScanError.denied : ScanError.unavailable).message)
            let checkpoint = try await repo.checkpoint(); XCTAssertNil(checkpoint)
            let photos = try await repo.photos(); XCTAssertTrue(photos.isEmpty)
        }
    }

    actor FailedDetector: DetectionProvider {
        func process(_ data: Data, contentVersion: Int) async throws -> ProcessedPreview { throw ScanError.database }
    }
    actor DisconnectingSource: PhotoSource {
        let data: Data
        var returned = false
        init(data: Data) { self.data = data }
        func open() async throws {}
        func next() async throws -> SourceEntry? {
            guard !returned else { throw ScanError.unavailable }
            returned = true; return SourceEntry(relativePath: "nested/accepted.jpg")
        }
        func read(_ entry: SourceEntry) async throws -> Data { data }
        func close() async {}
    }
    func testFailedAnalysisAndDisconnectRemainExplicitAndRetainAcceptedRecords() async throws {
        let folder = try directory()
        let failed = try CatalogRepository(directory: folder.appendingPathComponent("failed"), cacheDirectory: folder.appendingPathComponent("failed-cache"))
        let result = await ScanCoordinator(repository: failed).scan(source: TraceSource(data: try Self.jpeg()), detector: FailedDetector()) { _, _ in }
        XCTAssertEqual(result.phase, .completed); XCTAssertEqual(result.failed, 3)
        XCTAssertEqual(result.processed, 0); XCTAssertEqual(result.skipped, 0)
        let failedPhotos = try await failed.photos()
        XCTAssertTrue(failedPhotos.allSatisfy { $0.analysis.status == .failed && $0.contentVersion == $0.analysis.contentVersion })
        let disconnected = try CatalogRepository(directory: folder.appendingPathComponent("disconnected"), cacheDirectory: folder.appendingPathComponent("disconnected-cache"))
        let lost = await ScanCoordinator(repository: disconnected).scan(source: DisconnectingSource(data: try Self.jpeg()), detector: FixtureDetector()) { _, _ in }
        XCTAssertEqual(lost.phase, .failed); XCTAssertEqual(lost.message, ScanError.unavailable.message)
        XCTAssertFalse(lost.enumerationFinished); XCTAssertEqual(lost.processed, 1)
        let photos = try await disconnected.photos(); XCTAssertEqual(photos.count, 1)
        let checkpoint = try await disconnected.checkpoint(); XCTAssertEqual(checkpoint, lost)
    }

    actor RevisionSource: PhotoSource {
        let entries: [SourceEntry]
        let bytes: Data
        let root: String?
        let failure: ScanError?
        var index = 0
        var reads = 0
        var events: [String] = []
        init(paths: [String], bytes: Data, revision: String? = nil, root: String? = "volume:root", failure: ScanError? = nil) {
            entries = paths.map { SourceEntry(relativePath: $0, metadata: SourceMetadata(revision: revision, size: bytes.count)) }
            self.bytes = bytes; self.root = root; self.failure = failure
        }
        func identity() async throws -> String? { root }
        func open() async throws { events.append("open") }
        func next() async throws -> SourceEntry? {
            guard index < entries.count else {
                if let failure { throw failure }
                return nil
            }
            defer { index += 1 }; return entries[index]
        }
        func read(_ entry: SourceEntry) async throws -> Data { reads += 1; events.append("read"); return bytes }
        func close() async {}
        func cached() { events.append("cached") }
        func trace() -> [String] { events }
        func readCount() -> Int { reads }
    }
    actor IdentityDetector: DetectionProvider {
        var calls = 0
        let failure: ScanError?
        init(failure: ScanError? = nil) { self.failure = failure }
        func process(_ data: Data, contentVersion: Int) async throws -> ProcessedPreview {
            calls += 1
            if let failure { throw failure }
            return ProcessedPreview(jpeg: data, analysis: FaceAnalysisState(status: .successful, contentVersion: contentVersion,
                faces: [FaceGeometry(rectangle: [0, 0, 1, 1], landmarks: [])]))
        }
        func count() -> Int { calls }
    }
    private func repository() throws -> CatalogRepository {
        let base = try directory()
        return try CatalogRepository(directory: base.appendingPathComponent("db"), cacheDirectory: base.appendingPathComponent("cache"))
    }
    func testTrustedRevisionSkipsReadDecodeAndInferenceAcrossRestart() async throws {
        let repo = try repository(), detector = IdentityDetector()
        let first = RevisionSource(paths: ["a.jpg", "duplicate/a.jpg"], bytes: Data([1, 2]), revision: "r1")
        let scanned = await ScanCoordinator(repository: repo).scan(source: first, detector: detector) { _, _ in }
        XCTAssertEqual(scanned.phase, .completed)
        let before = try await repo.photos()
        let second = RevisionSource(paths: ["a.jpg", "duplicate/a.jpg"], bytes: Data([1, 2]), revision: "r1")
        let result = await ScanCoordinator(repository: repo).scan(source: second, detector: detector) { _, photo in
            if photo?.previewPath != nil { await second.cached() }
        }
        XCTAssertEqual(result.phase, .completed); XCTAssertEqual(result.processed, 2)
        let reads = await second.readCount(), calls = await detector.count()
        XCTAssertEqual(reads, 0); XCTAssertEqual(calls, 2)
        let after = try await repo.photos()
        XCTAssertEqual(after.map(\.id), before.map(\.id))
        XCTAssertEqual(after.map(\.analysis), before.map(\.analysis))
        XCTAssertNotEqual(after[0].id, after[1].id)
        XCTAssertNotEqual(after[0].analysis.faces[0].id, after[1].analysis.faces[0].id)
        let trace = await second.trace()
        XCTAssertLessThan(try XCTUnwrap(trace.firstIndex(of: "cached")), try XCTUnwrap(trace.firstIndex(of: "open")))
    }
    func testWeakMetadataHashesAfterCachedPreviewAndChangedBytesInvalidateFaces() async throws {
        let repo = try repository(), detector = IdentityDetector()
        _ = await ScanCoordinator(repository: repo).scan(source: RevisionSource(paths: ["a.jpg"], bytes: Data([1, 2])), detector: detector) { _, _ in }
        let beforeRecords = try await repo.photos()
            let before = try XCTUnwrap(beforeRecords.first)
        let same = RevisionSource(paths: ["a.jpg"], bytes: Data([1, 2]))
        _ = await ScanCoordinator(repository: repo).scan(source: same, detector: detector) { _, photo in
            if photo?.previewPath != nil { await same.cached() }
        }
        let preservedRecords = try await repo.photos()
            let preserved = try XCTUnwrap(preservedRecords.first)
        XCTAssertEqual(preserved.id, before.id); XCTAssertEqual(preserved.analysis, before.analysis)
        let trace = await same.trace()
        XCTAssertLessThan(try XCTUnwrap(trace.firstIndex(of: "cached")), try XCTUnwrap(trace.firstIndex(of: "read")))
        let calls = await detector.count(); XCTAssertEqual(calls, 1)
        _ = await ScanCoordinator(repository: repo).scan(source: RevisionSource(paths: ["a.jpg"], bytes: Data([3, 4])), detector: detector) { _, _ in }
        let changedRecords = try await repo.photos()
            let changed = try XCTUnwrap(changedRecords.first)
        XCTAssertEqual(changed.id, before.id); XCTAssertEqual(changed.contentVersion, 2)
        XCTAssertNotEqual(changed.analysis.faces[0].id, before.analysis.faces[0].id)
        XCTAssertNotEqual(changed.contentHash, before.contentHash)
        XCTAssertEqual(changed.analysis.contentVersion, changed.contentVersion)
    }
    func testDisconnectNeverMarksMissingButCompleteEnumerationDoes() async throws {
        let repo = try repository(), detector = IdentityDetector()
        _ = await ScanCoordinator(repository: repo).scan(source: RevisionSource(paths: ["a.jpg", "b.jpg"], bytes: Data([1])), detector: detector) { _, _ in }
        let before = try await repo.photos()
        for failure in [ScanError.unavailable, .denied] {
            let failed = await ScanCoordinator(repository: repo).scan(source: RevisionSource(paths: [], bytes: Data(), failure: failure), detector: detector) { _, _ in }
            XCTAssertEqual(failed.phase, .failed); XCTAssertFalse(failed.enumerationFinished)
            let retained = try await repo.photos(); XCTAssertEqual(retained, before)
        }
        let complete = await ScanCoordinator(repository: repo).scan(source: RevisionSource(paths: ["b.jpg"], bytes: Data([1])), detector: detector) { _, _ in }
        XCTAssertEqual(complete.phase, .completed)
        let after = try await repo.photos()
        XCTAssertEqual(after[0].missing, true); XCTAssertEqual(after[1].missing, false)
        XCTAssertEqual(after.map(\.analysis), before.map(\.analysis))
    }
    func testRegrantDifferentOrUnverifiableRootRequiresExplicitConfirmation() async throws {
        let repo = try repository(), detector = IdentityDetector()
        _ = await ScanCoordinator(repository: repo).scan(source: RevisionSource(paths: ["a.jpg"], bytes: Data([1])), detector: detector) { _, _ in }
        let before = try await repo.photos()
        for identity in [Optional("different-volume:root"), nil] {
            let source = RevisionSource(paths: ["a.jpg"], bytes: Data([2]), root: identity)
            let result = await ScanCoordinator(repository: repo).scan(source: source, detector: detector) { _, _ in }
            XCTAssertEqual(result.message, ScanError.sourceConfirmationRequired.message)
            let reads = await source.readCount(); XCTAssertEqual(reads, 0)
            let retained = try await repo.photos(); XCTAssertEqual(retained, before)
        }
        let accepted = await ScanCoordinator(repository: repo).scan(source: RevisionSource(paths: ["a.jpg"], bytes: Data([2]), root: nil), detector: detector, confirmedSource: true) { _, _ in }
        XCTAssertEqual(accepted.phase, .completed)
    }
    func testStorageAndLockPauseChangedGenerationAndResumeWithoutOldFaces() async throws {
        for failure in [ScanError.storagePressure, .paused] {
            let repo = try repository()
            _ = await ScanCoordinator(repository: repo).scan(source: RevisionSource(paths: ["a.jpg"], bytes: Data([1])), detector: IdentityDetector()) { _, _ in }
            let beforeRecords = try await repo.photos()
            let before = try XCTUnwrap(beforeRecords.first)
            let result = await ScanCoordinator(repository: repo).scan(source: RevisionSource(paths: ["a.jpg"], bytes: Data([2])), detector: IdentityDetector(failure: failure)) { _, _ in }
            XCTAssertEqual(result.phase, .paused); XCTAssertFalse(result.enumerationFinished)
            let pausedRecords = try await repo.photos()
            let paused = try XCTUnwrap(pausedRecords.first)
            XCTAssertEqual(paused.id, before.id); XCTAssertEqual(paused.contentVersion, 2)
            XCTAssertTrue(paused.analysis.faces.isEmpty); XCTAssertEqual(paused.analysis.status, .pending)
            let resumed = await ScanCoordinator(repository: repo).scan(source: RevisionSource(paths: ["a.jpg"], bytes: Data([2])), detector: IdentityDetector()) { _, _ in }
            XCTAssertEqual(resumed.phase, .completed); XCTAssertEqual(resumed.processed, 1)
            let afterRecords = try await repo.photos()
            let after = try XCTUnwrap(afterRecords.first)
            XCTAssertEqual(after.contentVersion, 2); XCTAssertEqual(after.id, before.id)
        }
    }

    actor GatedDetector: DetectionProvider {
        var entered = false
        var continuation: CheckedContinuation<Void, Never>?
        func process(_ data: Data, contentVersion: Int) async throws -> ProcessedPreview {
            entered = true
            await withCheckedContinuation { continuation = $0 }
            return ProcessedPreview(jpeg: data, analysis: FaceAnalysisState(status: .successful, contentVersion: contentVersion))
        }
        func started() -> Bool { entered }
        func release() { continuation?.resume(); continuation = nil }
    }
    actor ProgressTrace {
        var phases: [ScanPhase] = []
        func record(_ progress: ScanProgress) { phases.append(progress.phase) }
        func cancelling() -> Bool { phases.contains(.cancelling) }
    }
    func testCancellationRequestIsVisibleBeforeBoundedDetectorFinishesAndResumes() async throws {
        let repo = try repository(), scanner = ScanCoordinator(repository: repo)
        let detector = GatedDetector(), trace = ProgressTrace()
        let task = Task {
            await scanner.scan(source: RevisionSource(paths: ["a.jpg"], bytes: Data([1])), detector: detector) { progress, _ in
                await trace.record(progress)
            }
        }
        for _ in 0..<100 where !(await detector.started()) { try await Task.sleep(nanoseconds: 10_000_000) }
        let started = await detector.started(); XCTAssertTrue(started)
        let begin = Date()
        await scanner.cancel()
        let visible = await trace.cancelling(); XCTAssertTrue(visible)
        XCTAssertLessThan(Date().timeIntervalSince(begin), 2)
        await detector.release()
        let result = await task.value
        XCTAssertEqual(result.phase, .cancelled); XCTAssertEqual(result.processed, 0)
        let pending = try await repo.photos(); XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].analysis.status, .pending)
        let resumed = await ScanCoordinator(repository: repo).scan(source: RevisionSource(paths: ["a.jpg"], bytes: Data([1])), detector: IdentityDetector()) { _, _ in }
        XCTAssertEqual(resumed.phase, .completed)
        let records = try await repo.photos(); XCTAssertEqual(records[0].id, pending[0].id)
    }
    func testStaleCoordinatorCannotPublishResultAfterNewLease() async throws {
        let repo = try repository(), scanner = ScanCoordinator(repository: repo), detector = GatedDetector()
        let task = Task { await scanner.scan(source: RevisionSource(paths: ["a.jpg"], bytes: Data([1])), detector: detector) { _, _ in } }
        for _ in 0..<100 where !(await detector.started()) { try await Task.sleep(nanoseconds: 10_000_000) }
        let started = await detector.started(); XCTAssertTrue(started)
        let newer = await ScanCoordinator(repository: repo).scan(source: RevisionSource(paths: ["a.jpg"], bytes: Data([2])), detector: IdentityDetector()) { _, _ in }
        XCTAssertEqual(newer.phase, .completed)
        let accepted = try await repo.photos(), checkpoint = try await repo.checkpoint()
        await detector.release()
        let stale = await task.value
        XCTAssertEqual(stale.phase, .failed); XCTAssertEqual(stale.message, ScanError.staleLease.message)
        let after = try await repo.photos(), afterCheckpoint = try await repo.checkpoint()
        XCTAssertEqual(after, accepted); XCTAssertEqual(afterCheckpoint, checkpoint)
    }
    func testFolderChangedAfterDiscoveryCannotValidateOldMetadataOrMarkMissing() async throws {
        let root = try directory(), path = root.appendingPathComponent("a.jpg")
        try Data([1]).write(to: path)
        let source = FolderPhotoSource(root: root, grantForTesting: true)
        try await source.open()
        let entry = try await source.next()
        let discovered = try XCTUnwrap(entry)
        try Data([2, 3]).write(to: path)
        do { _ = try await source.read(discovered); XCTFail("Changed metadata accepted") }
        catch { XCTAssertEqual(error as? ScanError, .unavailable) }
        await source.close()
    }

    actor GenericReadFailure: PhotoSource {
        var returned = false
        func identity() async throws -> String? { "volume:root" }
        func open() async throws {}
        func next() async throws -> SourceEntry? {
            guard !returned else { return nil }
            returned = true; return SourceEntry(relativePath: "a.jpg")
        }
        func read(_ entry: SourceEntry) async throws -> Data { throw NSError(domain: "synthetic-read", code: 1) }
        func close() async {}
    }
    func testGenericReadFailureInvalidatesSuccessfulContentWithoutInheritingFaces() async throws {
        let repo = try repository()
        _ = await ScanCoordinator(repository: repo).scan(source: RevisionSource(paths: ["a.jpg"], bytes: Data([1])), detector: IdentityDetector()) { _, _ in }
        let beforeRecords = try await repo.photos(), before = try XCTUnwrap(beforeRecords.first)
        XCTAssertFalse(before.analysis.faces.isEmpty)
        let failed = await ScanCoordinator(repository: repo).scan(source: GenericReadFailure(), detector: IdentityDetector()) { _, _ in }
        XCTAssertEqual(failed.failed, 1)
        let afterRecords = try await repo.photos(), after = try XCTUnwrap(afterRecords.first)
        XCTAssertEqual(after.id, before.id); XCTAssertEqual(after.contentVersion, before.contentVersion + 1)
        XCTAssertEqual(after.analysis.status, .failed); XCTAssertTrue(after.analysis.faces.isEmpty)
        XCTAssertNil(after.contentHash); XCTAssertNil(after.previewPath)
        XCTAssertEqual(after.analysis.contentVersion, after.contentVersion)
    }
    func testNonnormalizedRootTerminatesAndRejectsEscape() async throws {
        let root = try directory(), nested = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let bytes = try Self.jpeg(); try bytes.write(to: root.appendingPathComponent("a.jpg"))
        let nonnormalized = nested.appendingPathComponent("..", isDirectory: true)
        let source = FolderPhotoSource(root: nonnormalized, grantForTesting: true)
        try await source.open()
        let read = try await source.read(SourceEntry(relativePath: "./a.jpg"))
        XCTAssertEqual(read, bytes)
        do { _ = try await source.read(SourceEntry(relativePath: "../outside.jpg")); XCTFail("Escape accepted") }
        catch { XCTAssertEqual(error as? ScanError, .unsafePath) }
        await source.close()
    }

    func testThrowingDetectorRetainsValidPreviewAndRestartRetriesUnresolvedAnalysis() async throws {
        let folder = try directory(), db = folder.appendingPathComponent("db"), cache = folder.appendingPathComponent("cache")
        let bytes = try Self.jpeg()
        var repo: CatalogRepository? = try CatalogRepository(directory: db, cacheDirectory: cache)
        let source = RevisionSource(paths: ["a.jpg"], bytes: bytes)
        let result = await ScanCoordinator(repository: repo!).scan(source: source, detector: FailedDetector()) { _, _ in }
        XCTAssertEqual(result.phase, .completed); XCTAssertEqual(result.failed, 1); XCTAssertEqual(result.processed, 0)
        let failedRecords = try await repo!.photos(), failed = try XCTUnwrap(failedRecords.first)
        XCTAssertEqual(failed.analysis.status, .failed); XCTAssertTrue(failed.analysis.faces.isEmpty)
        XCTAssertEqual(failed.analysis.contentVersion, failed.contentVersion)
        let preview = try XCTUnwrap(failed.previewPath)
        XCTAssertNoThrow(try JPEGPreviewDecoder.decode(Data(contentsOf: cache.appendingPathComponent(preview))))
        repo = nil
        let reopened = try CatalogRepository(directory: db, cacheDirectory: cache), retry = IdentityDetector()
        let resumed = await ScanCoordinator(repository: reopened).scan(source: RevisionSource(paths: ["a.jpg"], bytes: bytes), detector: retry) { _, _ in }
        XCTAssertEqual(resumed.processed, 1); XCTAssertEqual(resumed.failed, 0)
        let calls = await retry.count(); XCTAssertEqual(calls, 1)
        let restored = try await reopened.photos()
        XCTAssertEqual(restored[0].id, failed.id); XCTAssertEqual(restored[0].contentVersion, failed.contentVersion)
        XCTAssertEqual(restored[0].analysis.status, .successful)
        let invalid = try repository()
        let unreadable = await ScanCoordinator(repository: invalid).scan(source: RevisionSource(paths: ["bad.jpg"], bytes: Data([1, 2])), detector: FailedDetector()) { _, _ in }
        XCTAssertEqual(unreadable.failed, 1)
        let badRecords = try await invalid.photos(); XCTAssertNil(badRecords[0].previewPath)
    }

}
