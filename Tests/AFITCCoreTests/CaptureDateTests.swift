import XCTest
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
@testable import AFITCCore

final class CaptureDateTests: XCTestCase {
    private let original = "2024:02:29 23:45:06"
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func repository(_ root: URL) throws -> CatalogRepository {
        try CatalogRepository(directory: root.appendingPathComponent("db"), cacheDirectory: root.appendingPathComponent("cache"))
    }
    private func jpeg(original: String? = nil, offset: String? = nil, digitized: String? = nil, orientation: Int = 1) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 16, bitsPerComponent: 8,
            bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.25, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
        var exif: [CFString: Any] = [:]
        if let original { exif[kCGImagePropertyExifDateTimeOriginal] = original }
        if let offset { exif[kCGImagePropertyExifOffsetTimeOriginal] = offset }
        if let digitized { exif[kCGImagePropertyExifDateTimeDigitized] = digitized }
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()),
            [kCGImagePropertyExifDictionary: exif, kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
    actor Source: PhotoSource {
        let data: Data
        let revision: String?
        var yielded = false
        var reads = 0
        init(_ data: Data, revision: String? = nil) { self.data = data; self.revision = revision }
        func identity() -> String? { "capture-date-synthetic" }
        func open() { yielded = false }
        func next() -> SourceEntry? {
            guard !yielded else { return nil }; yielded = true
            return SourceEntry(relativePath: "fictional.jpg", metadata: SourceMetadata(revision: revision))
        }
        func read(_ entry: SourceEntry) -> Data { reads += 1; return data }
        func close() {}
        func readCount() -> Int { reads }
    }
    actor Detector: DetectionProvider {
        let fails: Bool
        var calls = 0
        init(fails: Bool = false) { self.fails = fails }
        func process(_ data: Data, contentVersion: Int) throws -> ProcessedPreview {
            calls += 1
            if fails { throw NSError(domain: "SyntheticDetector", code: 1) }
            let image = try JPEGPreviewDecoder.decode(data)
            return ProcessedPreview(jpeg: try JPEGPreviewDecoder.jpeg(image),
                analysis: FaceAnalysisState(status: .successful, contentVersion: contentVersion))
        }
        func count() -> Int { calls }
    }
    private func scan(_ repo: CatalogRepository, bytes: Data, revision: String? = nil, detector: Detector = Detector()) async -> ScanProgress {
        await ScanCoordinator(repository: repo).scan(source: Source(bytes, revision: revision), detector: detector) { _, _ in }
    }
    private func storedPhoto(_ repo: CatalogRepository) async throws -> PhotoIdentity {
        let photos = try await repo.photos()
        return try XCTUnwrap(photos.first)
    }
    func testOriginalJPEGMetadataAndSourceOffsetSurviveReencodingAndReopen() async throws {
        let root = try directory(), repo = try repository(root)
        let bytes = try jpeg(original: original, offset: "+14:30")
        let result = await scan(repo, bytes: bytes)
        XCTAssertEqual(result.phase, .completed); XCTAssertEqual(result.processed, 1)
        let records = try await repo.photos(), photo = try XCTUnwrap(records.first)
        XCTAssertEqual(photo.captureDate?.localWallClock, "2024-02-29T23:45:06")
        XCTAssertEqual(photo.captureDate?.sourceOffset, "+14:30")
        XCTAssertEqual(photo.captureDate?.provenance, "exif.dateTimeOriginal")
        let cached = try Data(contentsOf: root.appendingPathComponent("cache").appendingPathComponent(try XCTUnwrap(photo.previewPath)))
        XCTAssertNil(CaptureDateMetadata.extract(fromValidatedJPEG: cached), "A stripped preview cannot be the metadata producer")
        let reopened = try repository(root), persisted = try await reopened.photos()
        XCTAssertEqual(persisted.first?.captureDate, photo.captureDate)
    }
    func testSourceOffsetConservativeAppSubsetPreservesDateAndNegativeZero() throws {
        for value in ["+14:30", "+23:59", "-00:00", "-05:45"] {
            let metadata = CaptureDateMetadata.extract(fromValidatedJPEG: try jpeg(original: original, offset: value))
            XCTAssertEqual(metadata?.sourceOffset, value)
        }
        for value in ["+24:00", "+99:00", "+01:60", "+1:00", "Z", "   :  "] {
            let metadata = CaptureDateMetadata.extract(fromValidatedJPEG: try jpeg(original: original, offset: value))
            XCTAssertEqual(metadata?.localWallClock, "2024-02-29T23:45:06"); XCTAssertNil(metadata?.sourceOffset)
        }
        XCTAssertNil(CaptureDateMetadata.extract(fromValidatedJPEG: try jpeg(original: original))?.sourceOffset)
        XCTAssertEqual(CaptureDateMetadata.parse(original: original + "\0", offset: "-00:00\0")?.sourceOffset, "-00:00")
        XCTAssertNil(CaptureDateMetadata.parse(original: original + "\0\0", offset: nil))
    }
    func testMissingMalformedCalendarInvalidAndDigitizedOnlyRemainUnknown() throws {
        for value in ["", "    :  :     :  :  ", "2023:02:29 12:00:00", "1900:02:29 12:00:00",
                      "2024:04:31 12:00:00", "0000:01:01 00:00:00", "2024:01:01 24:00:00",
                      "2024:01:01 00:60:00", "2024:01:01 00:00:60", "2024-01-01 00:00:00"] {
            XCTAssertNil(CaptureDateMetadata.extract(fromValidatedJPEG: try jpeg(original: value)))
        }
        XCTAssertNil(CaptureDateMetadata.extract(fromValidatedJPEG: try jpeg(digitized: original)))
        XCTAssertNil(CaptureDateMetadata.extract(fromValidatedJPEG: try jpeg()))
        XCTAssertNotNil(CaptureDateMetadata.parse(original: "2000:02:29 00:00:00", offset: nil))
        XCTAssertNotNil(CaptureDateMetadata.parse(original: "0001:01:01 00:00:00", offset: nil))
        XCTAssertNotNil(CaptureDateMetadata.parse(original: "9999:12:31 23:59:59", offset: nil))
    }
    func testOrientationSixRetainsOriginalMetadataAndBoundedUprightDimensions() throws {
        let bytes = try jpeg(original: original, offset: "+02:00", orientation: 6)
        let metadata = CaptureDateMetadata.extract(fromValidatedJPEG: bytes)
        let upright = try JPEGPreviewDecoder.decode(bytes)
        XCTAssertEqual(upright.width, 16); XCTAssertEqual(upright.height, 32)
        XCTAssertEqual(metadata?.localWallClock, "2024-02-29T23:45:06")
        XCTAssertEqual(metadata?.sourceOffset, "+02:00")
    }
    func testChangedContentReplacesThenClearsCaptureDateWithNewGeneration() async throws {
        let repo = try repository(directory())
        _ = await scan(repo, bytes: try jpeg(original: original))
        let first = try await storedPhoto(repo)
        _ = await scan(repo, bytes: try jpeg(original: "2025:01:02 03:04:05"))
        let second = try await storedPhoto(repo)
        XCTAssertEqual(second.id, first.id); XCTAssertEqual(second.contentVersion, first.contentVersion + 1)
        XCTAssertEqual(second.captureDate?.localWallClock, "2025-01-02T03:04:05")
        _ = await scan(repo, bytes: try jpeg(digitized: original))
        let third = try await storedPhoto(repo)
        XCTAssertEqual(third.contentVersion, second.contentVersion + 1); XCTAssertNil(third.captureDate)
    }
    func testWeakExactHashBackfillsLegacyCaptureDateWithoutDetectionOrVersionChange() async throws {
        let repo = try repository(directory()), bytes = try jpeg(original: original), detector = Detector()
        _ = await scan(repo, bytes: bytes, detector: detector)
        var photo = try await storedPhoto(repo)
        photo.captureDate = nil
        try await repo.save(photo, progress: ScanProgress())
        let source = Source(bytes)
        _ = await ScanCoordinator(repository: repo).scan(source: source, detector: detector) { _, _ in }
        let after = try await storedPhoto(repo)
        XCTAssertEqual(after.id, photo.id); XCTAssertEqual(after.contentVersion, photo.contentVersion)
        XCTAssertNotNil(after.captureDate)
        let reads = await source.readCount(), calls = await detector.count()
        XCTAssertEqual(reads, 1); XCTAssertEqual(calls, 1)
    }
    func testTrustedNoReadReusePreservesKnownAndUnknownCaptureDate() async throws {
        for known in [true, false] {
            let repo = try repository(directory()), detector = Detector()
            let bytes = try jpeg(original: known ? original : nil)
            _ = await scan(repo, bytes: bytes, revision: "provider-guaranteed-r1", detector: detector)
            let before = try await storedPhoto(repo)
            let source = Source(Data("must not be read".utf8), revision: "provider-guaranteed-r1")
            _ = await ScanCoordinator(repository: repo).scan(source: source, detector: detector) { _, _ in }
            let after = try await storedPhoto(repo)
            XCTAssertEqual(after.captureDate, before.captureDate); XCTAssertEqual(after.contentVersion, before.contentVersion)
            let reads = await source.readCount(), calls = await detector.count()
            XCTAssertEqual(reads, 0); XCTAssertEqual(calls, 1)
        }
    }
    func testDetectionFailureFallbackUsesOriginalMetadataAndMalformedBytesStayUnknown() async throws {
        let repo = try repository(directory())
        let result = await scan(repo, bytes: try jpeg(original: original), detector: Detector(fails: true))
        XCTAssertEqual(result.failed, 1)
        let first = try await storedPhoto(repo)
        XCTAssertEqual(first.analysis.status, .failed); XCTAssertNotNil(first.previewPath); XCTAssertNotNil(first.captureDate)
        let invalid = await scan(repo, bytes: Data("not JPEG".utf8))
        XCTAssertEqual(invalid.skipped, 1)
        let after = try await storedPhoto(repo)
        XCTAssertEqual(after.analysis.status, .skipped); XCTAssertNil(after.captureDate)
        // Real EXIF-bearing JPEG metadata must not bypass the bounded header validator.
        var oversized = try jpeg(original: original)
        let frame = try XCTUnwrap((0..<(oversized.count - 8)).first {
            oversized[$0] == 0xff && oversized[$0 + 1] == 0xc0
        })
        oversized[frame + 7] = 0xff; oversized[frame + 8] = 0xff
        let rejected = await scan(repo, bytes: oversized)
        XCTAssertEqual(rejected.skipped, 1)
        let skipped = try await storedPhoto(repo)
        XCTAssertEqual(skipped.analysis.status, .skipped); XCTAssertNil(skipped.captureDate)
    }
    func testPersistedMetadataRejectsInvalidSortKeysOffsetsAndProvenance() throws {
        let valid = try XCTUnwrap(CaptureDateMetadata.parse(original: original, offset: "+14:30"))
        let encoded = try JSONEncoder().encode(valid)
        XCTAssertEqual(try JSONDecoder().decode(CaptureDateMetadata.self, from: encoded), valid)
        let good = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var cases: [[String: Any]] = []
        for local in ["arbitrary sort key", "2023-02-29T23:45:06", "2024:02:29 23:45:06",
                      "２０２４-02-29T23:45:06", "2024-02-29T23:45:60", "2024-02-29T23:45:06\0"] {
            var value = good; value["localWallClock"] = local; cases.append(value)
        }
        for offset in ["+24:00", "+99:00", "+01:60", "+14:30\0", "not an offset"] {
            var value = good; value["sourceOffset"] = offset; cases.append(value)
        }
        var wrongProvenance = good; wrongProvenance["provenance"] = "importDate"; cases.append(wrongProvenance)
        var missingProvenance = good; missingProvenance.removeValue(forKey: "provenance"); cases.append(missingProvenance)
        var wrongType = good; wrongType["sourceOffset"] = 14; cases.append(wrongType)
        let photo = PhotoIdentity(relativePath: "fictional.jpg", captureDate: valid)
        let photoJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(photo)) as? [String: Any])
        for value in cases {
            let metadataData = try JSONSerialization.data(withJSONObject: value)
            XCTAssertThrowsError(try JSONDecoder().decode(CaptureDateMetadata.self, from: metadataData)) { error in
                guard case DecodingError.dataCorrupted = error else { return XCTFail("Expected corrupt metadata rejection") }
            }
            var invalidPhoto = photoJSON; invalidPhoto["captureDate"] = value
            let photoData = try JSONSerialization.data(withJSONObject: invalidPhoto)
            XCTAssertThrowsError(try JSONDecoder().decode(PhotoIdentity.self, from: photoData)) { error in
                guard case DecodingError.dataCorrupted = error else { return XCTFail("Expected corrupt photo metadata rejection") }
            }
        }
    }
    func testLegacyMissingCaptureDateDecodesNilAndRoundTripPreservesOptionalValue() throws {
        let photo = PhotoIdentity(relativePath: "fictional.jpg")
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(photo)) as? [String: Any])
        payload.removeValue(forKey: "captureDate")
        let legacy = try JSONDecoder().decode(PhotoIdentity.self, from: JSONSerialization.data(withJSONObject: payload))
        XCTAssertNil(legacy.captureDate)
        var current = legacy
        current.captureDate = CaptureDateMetadata.parse(original: original, offset: nil)
        XCTAssertEqual(try JSONDecoder().decode(PhotoIdentity.self, from: JSONEncoder().encode(current)), current)
    }
}
