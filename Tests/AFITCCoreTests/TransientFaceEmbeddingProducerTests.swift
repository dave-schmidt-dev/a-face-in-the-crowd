@testable import AFITCCore
@testable import AFITCRuntime
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// Canvas-space face written into one stride-32 cell of the fake YuNet heads.
struct ProducerCanvasFace: Sendable {
    var row = 10, column = 10
    var centerX: Float = 320, centerY: Float = 320, width: Float = 320, height: Float = 256
    var points: [[Float]] = [[260, 270], [380, 270], [320, 320], [270, 380], [370, 380]]
}

/// Ordered cross-actor event trace used for causal assertions.
final class ProducerTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var events: [String] { lock.withLock { stored } }
    func append(_ event: String) { lock.withLock { stored.append(event) } }
    func index(_ event: String) -> Int? { events.firstIndex(of: event) }
    func count(_ event: String) -> Int { events.filter { $0 == event }.count }
}

/// Holds an async backend until released; cancellation does not resume it, so drain is real.
actor ProducerHoldGate {
    private var entered = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func enter() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { released = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
    func waitEntered() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !entered {
            guard ContinuousClock.now < deadline else { XCTFail("Held backend was not entered"); return }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

/// Fake ORT YuNet session returning all twelve pinned heads with exact shapes.
final class ProducerYuNetBackend: YuNetInferenceBackend, @unchecked Sendable {
    let inputNames = [YuNetRuntimeContract.inputName]
    let outputNames = YuNetRuntimeContract.outputNames
    let faces: [ProducerCanvasFace]
    let gate: ProducerHoldGate?
    let trace: ProducerTrace
    private let lock = NSLock()
    private var inputs: [YuNetRuntimeTensor] = []
    init(faces: [ProducerCanvasFace] = [ProducerCanvasFace()], gate: ProducerHoldGate? = nil,
         trace: ProducerTrace = ProducerTrace()) {
        self.faces = faces; self.gate = gate; self.trace = trace
    }
    var calls: Int { lock.withLock { inputs.count } }
    var lastInput: YuNetRuntimeTensor? { lock.withLock { inputs.last } }
    func infer(_ input: YuNetRuntimeTensor) async throws -> [YuNetRuntimeTensor] {
        lock.withLock { inputs.append(input) }
        trace.append("yunet-entered")
        if let gate { await gate.enter() }
        trace.append("yunet-returned")
        return Self.heads(faces)
    }
    static func heads(_ faces: [ProducerCanvasFace]) -> [YuNetRuntimeTensor] {
        [8, 16, 32].flatMap { stride -> [YuNetRuntimeTensor] in
            let side = 640 / stride, count = side * side
            var cls = [Float](repeating: 0, count: count), obj = cls
            var bbox = [Float](repeating: 0, count: count * 4), kps = [Float](repeating: 0, count: count * 10)
            if stride == 32 {
                for face in faces {
                    let index = face.row * side + face.column, s = Float(stride)
                    cls[index] = 1; obj[index] = 1
                    bbox[index * 4] = face.centerX / s - Float(face.column)
                    bbox[index * 4 + 1] = face.centerY / s - Float(face.row)
                    bbox[index * 4 + 2] = Foundation.log(face.width / s)
                    bbox[index * 4 + 3] = Foundation.log(face.height / s)
                    for (slot, point) in face.points.enumerated() {
                        kps[index * 10 + slot * 2] = point[0] / s - Float(face.column)
                        kps[index * 10 + slot * 2 + 1] = point[1] / s - Float(face.row)
                    }
                }
            }
            func tensor(_ kind: String, _ values: [Float], _ channels: Int) -> YuNetRuntimeTensor {
                YuNetRuntimeTensor(name: "\(kind)_\(stride)", elementType: .float32,
                                   shape: [1, count, channels], values: values)
            }
            return [tensor("cls", cls, 1), tensor("obj", obj, 1), tensor("bbox", bbox, 4), tensor("kps", kps, 10)]
        }
    }
}

/// Fake SFace session returning a deliberately non-unit raw vector per call.
final class ProducerSFaceBackend: EmbeddingInferenceBackend, @unchecked Sendable {
    static let manifest = ModelManifest.openCVSFace2021December
    let metadata = EmbeddingRuntimeMetadata(
        inputNames: [manifest.inputName], inputShape: manifest.inputShape, inputElementType: .float32,
        outputNames: [manifest.outputName], outputShape: manifest.outputShape, outputElementType: .float32)
    let gate: ProducerHoldGate?
    let trace: ProducerTrace
    private let lock = NSLock()
    private var inputs: [ModelTensor] = []
    init(gate: ProducerHoldGate? = nil, trace: ProducerTrace = ProducerTrace()) { self.gate = gate; self.trace = trace }
    var calls: Int { lock.withLock { inputs.count } }
    var recordedInputs: [ModelTensor] { lock.withLock { inputs } }
    static func raw(_ call: Int) -> [Float] { (0..<128).map { Float($0) * 0.125 - 7.5 + Float(call) } }
    func infer(_ input: ModelTensor) async throws -> EmbeddingVector {
        let call = lock.withLock { inputs.append(input); return inputs.count - 1 }
        trace.append("sface-entered")
        if let gate { await gate.enter() }
        trace.append("sface-returned")
        return EmbeddingVector(modelIdentifier: Self.manifest.identifier, values: Self.raw(call))
    }
}

struct ProducerFakeLoader: FacePipelineModelLoader {
    let yuNet: ProducerYuNetBackend
    let sFace: ProducerSFaceBackend
    let loads = SFaceLockedCount()
    var fails = false
    func load() async throws -> FacePipelineModels {
        loads.increment()
        if fails { throw YuNetRuntimeError.modelUnavailable }
        return FacePipelineModels(yuNet: YuNetRuntime(backend: yuNet),
                                  sFace: FaceEmbeddingRuntime(manifest: ProducerSFaceBackend.manifest, backend: sFace))
    }
}

final class ProducerMessages: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var values: [String] { lock.withLock { stored } }
    func append(_ value: String) { lock.withLock { stored.append(value) } }
}

/// Isolated owned catalog with a confirmed source binding and a 96x64 non-square JPEG.
struct ProducerHarness {
    static let sourceIdentity = "volume:root"
    static let detectorVersion = "vision-test-r3"
    /// Vision box (normalized, lower-left origin) that uniquely overlaps the default YuNet face.
    static let primaryRect: [Double] = [0.25, 0.2, 0.5, 0.6]
    let catalog: CatalogRepository
    let store = TransientFaceEmbeddingStore()
    let bytes: Data
    let hash: String

    static func make(_ test: XCTestCase) async throws -> ProducerHarness {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AFITCProducer-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let catalog = try CatalogRepository(directory: root.appendingPathComponent("Catalog"),
                                            cacheDirectory: root.appendingPathComponent("Cache"))
        _ = try await catalog.acquireSource(identity: sourceIdentity, confirmed: true)
        let bytes = try jpeg(width: 96, height: 64)
        return ProducerHarness(catalog: catalog, bytes: bytes, hash: sha256(bytes))
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func jpeg(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.7, green: 0.55, blue: 0.45, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.2, green: 0.25, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: width / 3, y: height / 3, width: width / 3, height: height / 4))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    @discardableResult
    func savePhoto(rects: [[Double]], path: String = "photo.jpg") async throws -> PhotoIdentity {
        let faces = rects.map { FaceGeometry(rectangle: $0, landmarks: []) }
        let photo = PhotoIdentity(relativePath: path, analysis: FaceAnalysisState(status: .successful,
            detectorVersion: Self.detectorVersion, faces: faces),
            metadata: SourceMetadata(revision: "r1", size: bytes.count), contentHash: hash)
        try await catalog.save(photo, progress: ScanProgress())
        return photo
    }

    func producer(_ loader: ProducerFakeLoader, operationID: UUID = UUID(), session: UInt64 = 7)
        -> TransientFaceEmbeddingProducer {
        TransientFaceEmbeddingProducer(repository: catalog, store: store,
            token: store.begin(operationID: operationID, sessionEpoch: session), loader: loader)
    }

    func request(_ photo: PhotoIdentity, hash: String? = nil) -> ScanEnrichmentRequest {
        ScanEnrichmentRequest(photo: photo, entry: SourceEntry(relativePath: photo.relativePath),
            sourceIdentity: Self.sourceIdentity, bytes: bytes, contentHash: hash ?? self.hash)
    }

    /// Independent expectation of the qualified pixel-center inverse mapping for this frame.
    static func expectedPoints(_ face: ProducerCanvasFace = ProducerCanvasFace()) throws -> SFaceFivePoints {
        let scaleX = 640.0 / 96.0, resizedHeight = floor(64.0 * scaleX + 0.5), scaleY = resizedHeight / 64.0
        let padTop = Double((640 - Int(resizedHeight)) / 2)
        let mapped = face.points.map {
            SFacePoint(x: Float((Double($0[0]) + 0.5) / scaleX - 0.5),
                       y: Float(((Double($0[1]) - padTop) + 0.5) / scaleY - 0.5))
        }
        return try SFaceFivePoints(mapped[0], mapped[1], mapped[2], mapped[3], mapped[4])
    }
}

func expectProducerError(_ expected: TransientFaceEmbeddingError, file: StaticString = #filePath, line: UInt = #line,
                         _ body: () async throws -> Void) async {
    do { try await body(); XCTFail("Expected \(expected)", file: file, line: line) }
    catch { XCTAssertEqual(error as? TransientFaceEmbeddingError, expected, file: file, line: line) }
}

final class TransientFaceEmbeddingProducerTests: XCTestCase {
    func testComposedPipelineReturnsExactRawOutputAndProvenanceForVisionUUID() async throws {
        let h = try await ProducerHarness.make(self)
        let photo = try await h.savePhoto(rects: [ProducerHarness.primaryRect])
        let yuNet = ProducerYuNetBackend(), sFace = ProducerSFaceBackend()
        let operation = UUID()
        let producer = h.producer(ProducerFakeLoader(yuNet: yuNet, sFace: sFace), operationID: operation, session: 11)
        try await producer.enrich(h.request(photo)) { _ in }

        // Stage 1-2: canonical oriented RGB packed by the qualified fixed-640 BGR preprocessor.
        let raster = try JPEGPreviewDecoder.canonicalRGB(h.bytes)
        let prepared = try YuNetRasterPreprocessor.prepare(raster: raster)
        XCTAssertEqual(yuNet.calls, 1)
        XCTAssertEqual(yuNet.lastInput?.shape, YuNetRuntimeContract.inputShape)
        XCTAssertEqual(yuNet.lastInput?.values, prepared.modelInput.values)
        XCTAssertEqual(prepared.geometry.padTop, 106)
        // Stage 4-6: decoded, inverse-mapped points crop the SFace input.
        let points = try ProducerHarness.expectedPoints()
        let crop = try SFacePreprocessor.prepare(raster: raster, points: points)
        XCTAssertEqual(sFace.recordedInputs, [crop.modelInput])

        let batch = try XCTUnwrap(h.store.latestBatch)
        XCTAssertEqual(batch.photoID, photo.id); XCTAssertEqual(batch.contentVersion, photo.contentVersion)
        XCTAssertEqual(batch.operationID, operation); XCTAssertEqual(batch.sessionEpoch, 11)
        XCTAssertEqual(batch.sourceIdentity, ProducerHarness.sourceIdentity)
        XCTAssertEqual(batch.yuNetModelIdentifier, YuNetRuntimeContract.identifier)
        XCTAssertEqual(batch.sFaceModelIdentifier, ProducerSFaceBackend.manifest.identifier)
        XCTAssertEqual(batch.rows.map(\.visionFaceID), photo.analysis.faces.map(\.id))
        let manifest = ProducerSFaceBackend.manifest
        let provenance = FaceEmbeddingProvenance(photoID: photo.id, contentVersion: photo.contentVersion,
            faceID: photo.analysis.faces[0].id, detectorVersion: ProducerHarness.detectorVersion,
            operationID: operation, sessionEpoch: 11, modelIdentifier: manifest.identifier,
            preprocessingVersion: manifest.preprocessingVersion)
        guard case .embedded(let result, let used) = batch.rows[0].outcome else { return XCTFail("Not embedded") }
        XCTAssertEqual(result.provenance, provenance)
        XCTAssertEqual(result.embedding, EmbeddingVector(modelIdentifier: manifest.identifier, values: ProducerSFaceBackend.raw(0)))
        XCTAssertNotEqual(result.embedding.values.reduce(0) { $0 + $1 * $1 }, 1, "raw vector must not be normalized")
        for (actual, expected) in zip([used.point0, used.point1, used.point2, used.point3, used.point4],
                                      [points.point0, points.point1, points.point2, points.point3, points.point4]) {
            XCTAssertEqual(actual.x, expected.x, accuracy: 1e-4); XCTAssertEqual(actual.y, expected.y, accuracy: 1e-4)
        }
        try await batch.revalidate(in: h.catalog, verifiedContentHash: h.hash)
        let stored = try await h.catalog.photos().first { $0.id == photo.id }
        XCTAssertEqual(stored?.analysis, photo.analysis, "producer never writes the catalog")
    }

    func testZeroFacesSkipModelsAndAmbiguousOrUnmatchedFacesSkipEmbedding() async throws {
        let h = try await ProducerHarness.make(self)
        let empty = try await h.savePhoto(rects: [], path: "empty.jpg")
        let yuNet = ProducerYuNetBackend(), sFace = ProducerSFaceBackend()
        let loader = ProducerFakeLoader(yuNet: yuNet, sFace: sFace)
        try await h.producer(loader).enrich(h.request(empty)) { _ in }
        XCTAssertEqual(loader.loads.value, 0); XCTAssertEqual(yuNet.calls, 0)
        XCTAssertEqual(h.store.latestBatch?.rows.count, 0); XCTAssertEqual(h.store.latestBatch?.photoID, empty.id)

        let ambiguous = try await h.savePhoto(rects: [ProducerHarness.primaryRect, [0.3, 0.25, 0.4, 0.5]], path: "a.jpg")
        try await h.producer(loader).enrich(h.request(ambiguous)) { _ in }
        XCTAssertEqual(h.store.latestBatch?.rows.map(\.outcome),
                       [.unavailable(.association(.ambiguousOverlap)), .unavailable(.association(.ambiguousOverlap))])
        XCTAssertEqual(Set(h.store.latestBatch?.rows.map(\.visionFaceID) ?? []), Set(ambiguous.analysis.faces.map(\.id)))
        XCTAssertEqual(sFace.calls, 0)

        let mixed = try await h.savePhoto(rects: [[0.0, 0.85, 0.1, 0.1], ProducerHarness.primaryRect], path: "m.jpg")
        try await h.producer(loader).enrich(h.request(mixed)) { _ in }
        let rows = try XCTUnwrap(h.store.latestBatch?.rows)
        XCTAssertEqual(rows.map(\.visionFaceID), h.store.latestBatch?.fence.faces.map(\.geometry.id), "fence order")
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.visionFaceID, $0.outcome) })
        XCTAssertEqual(byID[mixed.analysis.faces[0].id], .unavailable(.association(.noPositiveIoU)))
        guard case .embedded = byID[mixed.analysis.faces[1].id] else { return XCTFail("Unique face not embedded") }
        XCTAssertEqual(sFace.calls, 1)

        let noYuNet = ProducerFakeLoader(yuNet: ProducerYuNetBackend(faces: []), sFace: sFace)
        try await h.producer(noYuNet).enrich(h.request(mixed)) { _ in }
        XCTAssertEqual(h.store.latestBatch?.rows.map(\.outcome),
                       [.unavailable(.association(.noPositiveIoU)), .unavailable(.association(.noPositiveIoU))])
        XCTAssertEqual(sFace.calls, 1)
    }

    func testHashMismatchAndIneligiblePhotoPublishNothing() async throws {
        let h = try await ProducerHarness.make(self)
        let photo = try await h.savePhoto(rects: [ProducerHarness.primaryRect])
        let yuNet = ProducerYuNetBackend(), loader = ProducerFakeLoader(yuNet: yuNet, sFace: ProducerSFaceBackend())
        await expectProducerError(.stale) {
            try await h.producer(loader).enrich(h.request(photo, hash: String(repeating: "f", count: 64))) { _ in }
        }
        var pending = photo; pending.analysis = FaceAnalysisState(status: .pending)
        try await h.catalog.save(pending, progress: ScanProgress())
        await expectProducerError(.ineligible) { try await h.producer(loader).enrich(h.request(pending)) { _ in } }
        XCTAssertNil(h.store.latestBatch); XCTAssertEqual(yuNet.calls, 0)
    }

    func testPhotoManualSourceAndSessionChangesDuringHeldInferenceAreStale() async throws {
        let mutations: [(String, (ProducerHarness, PhotoIdentity) async throws -> Void)] = [
            ("photo", { h, p in var changed = p; changed.metadata = SourceMetadata(revision: "r2", size: 1)
                try await h.catalog.save(changed, progress: ScanProgress()) }),
            ("manual", { h, p in _ = try await h.catalog.applyDecision(
                .name(face: FaceKey(photo: p, face: p.analysis.faces[0]), displayName: "Pat")) }),
            ("source", { h, _ in _ = try await h.catalog.acquireSource(identity: "volume:other", confirmed: true) }),
            ("session", { h, _ in h.store.invalidate() })
        ]
        for (name, mutate) in mutations {
            let h = try await ProducerHarness.make(self)
            let photo = try await h.savePhoto(rects: [ProducerHarness.primaryRect])
            let gate = ProducerHoldGate(), yuNet = ProducerYuNetBackend(gate: gate), sFace = ProducerSFaceBackend()
            let producer = h.producer(ProducerFakeLoader(yuNet: yuNet, sFace: sFace))
            let run = Task { try await producer.enrich(h.request(photo)) { _ in } }
            try await gate.waitEntered()
            try await mutate(h, photo)
            await gate.release()
            await expectProducerError(.stale) { try await run.value }
            XCTAssertNil(h.store.latestBatch, name)
            XCTAssertTrue(yuNet.trace.events.contains("yunet-returned"), "\(name): runtime drained before stale")
            if name == "session" { XCTAssertEqual(sFace.calls, 0, name) }
        }
    }

    func testProgressIsVisibleOrderedAndFreeOfImplementationDetail() async throws {
        let h = try await ProducerHarness.make(self)
        let photo = try await h.savePhoto(rects: [ProducerHarness.primaryRect, [0.0, 0.85, 0.1, 0.1]])
        let messages = ProducerMessages()
        let producer = h.producer(ProducerFakeLoader(yuNet: ProducerYuNetBackend(), sFace: ProducerSFaceBackend()))
        try await producer.enrich(h.request(photo)) { messages.append($0) }
        XCTAssertEqual(messages.values, ["Preparing on-device face models for face details.",
                                         "Finding face details for this photo.",
                                         "Computing face details for face 1 of 1.",
                                         "Face details ready for 1 of 2 detected faces in this photo."])
        let forbidden = [h.hash, photo.id.uuidString, photo.relativePath, ".onnx", "/", "YuNet", "SFace",
                         YuNetRuntimeContract.identifier, ProducerHarness.sourceIdentity]
        for message in messages.values { for detail in forbidden { XCTAssertFalse(message.contains(detail), message) } }

        let later = ProducerMessages()
        try await producer.enrich(h.request(photo)) { later.append($0) }
        XCTAssertFalse(later.values.contains("Preparing on-device face models for face details."), "models reused")
        h.store.invalidate()
        let silenced = ProducerMessages()
        await expectProducerError(.stale) { try await producer.enrich(h.request(photo)) { silenced.append($0) } }
        XCTAssertTrue(silenced.values.isEmpty)
    }

    /// Opt-in actual host CPU composition run. Inputs come only from explicit environment paths;
    /// output (counts, stages, model and source pins only) goes only to the explicit output file.
    func testActualHostCPUPipelineDiagnosticWhenOptedIn() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["AFITC_RUN_PRODUCER_PIPELINE_DIAGNOSTIC"] == "1",
              let yuNetPath = env["AFITC_PRODUCER_YUNET_MODEL_PATH"], let sFacePath = env["AFITC_PRODUCER_SFACE_MODEL_PATH"],
              let jpegPath = env["AFITC_PRODUCER_JPEG_PATH"], let outputPath = env["AFITC_PRODUCER_DIAGNOSTIC_OUTPUT"] else {
            throw XCTSkip("Actual producer pipeline diagnostic requires explicit opt-in and local artifact paths")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AFITCProducerDiag-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try CatalogRepository(directory: root.appendingPathComponent("Catalog"),
                                            cacheDirectory: root.appendingPathComponent("Cache"))
        let identity = "diagnostic:isolated"
        _ = try await catalog.acquireSource(identity: identity, confirmed: true)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: jpegPath))
        let hash = ProducerHarness.sha256(bytes)
        // Actual Vision runs once to establish the accepted face UUIDs the producer must preserve.
        let processed = try await VisionJPEGDetector().process(bytes, contentVersion: 1)
        let photo = PhotoIdentity(relativePath: "diagnostic.jpg", analysis: processed.analysis, contentHash: hash)
        try await catalog.save(photo, progress: ScanProgress())
        let store = TransientFaceEmbeddingStore()
        let producer = TransientFaceEmbeddingProducer(repository: catalog, store: store,
            token: store.begin(operationID: UUID(), sessionEpoch: 1),
            loader: LocalFacePipelineModelLoader(yuNetURL: URL(fileURLWithPath: yuNetPath),
                                                 sFaceURL: URL(fileURLWithPath: sFacePath)))
        let stages = ProducerMessages()
        var outcome = "published"
        do {
            try await producer.enrich(ScanEnrichmentRequest(photo: photo, entry: SourceEntry(relativePath: photo.relativePath),
                sourceIdentity: identity, bytes: bytes, contentHash: hash)) { stages.append($0) }
        } catch let error as TransientFaceEmbeddingError { outcome = "\(error)" }
        await producer.release()
        let batch = store.latestBatch
        if outcome == "published" {
            let rows = try XCTUnwrap(batch?.rows)
            XCTAssertEqual(rows.count, photo.analysis.faces.count)
            XCTAssertEqual(Set(rows.map(\.visionFaceID)), Set(photo.analysis.faces.map(\.id)), "Vision UUIDs preserved")
            for row in rows { if case .embedded(let result, _) = row.outcome { XCTAssertEqual(result.embedding.values.count, 128) } }
        }
        var reasons: [String: Int] = [:]
        for row in batch?.rows ?? [] {
            if case .unavailable(let reason) = row.outcome { reasons["\(reason)", default: 0] += 1 }
        }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let composition = ["Sources/AFITCRuntime/TransientFaceEmbeddingProducer.swift", "Sources/AFITCCore/ScanCoordinator.swift",
                           "Tests/AFITCCoreTests/TransientFaceEmbeddingProducerTests.swift"]
        var sources: [String: String] = [:]
        for path in composition { sources[path] = ProducerHarness.sha256(try Data(contentsOf: repo.appendingPathComponent(path))) }
        let report: [String: Any] = [
            "outcome": outcome, "visionFaces": photo.analysis.faces.count, "rows": batch?.rows.count ?? 0,
            "embedded": batch?.rows.filter { if case .embedded = $0.outcome { return true }; return false }.count ?? 0,
            "unavailable": reasons, "stages": stages.values,
            "yuNetPin": ["identifier": YuNetRuntimeContract.identifier, "sha256": YuNetRuntimeContract.artifactSHA256,
                         "preprocessing": YuNetRuntimeContract.preprocessingVersion],
            "sFacePin": ["identifier": ProducerSFaceBackend.manifest.identifier, "sha256": ProducerSFaceBackend.manifest.artifactSHA256,
                         "preprocessing": ProducerSFaceBackend.manifest.preprocessingVersion],
            "compositionSourceSHA256": sources,
            "claims": "mechanics only; no tolerance, usefulness or identity claim"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }
}
