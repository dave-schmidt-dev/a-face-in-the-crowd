@testable import AFITCCore
import Foundation
import XCTest

/// Fake vector producer: no models. Optionally holds (ignoring cancellation, so drain is real)
/// and then echoes the original request's photo, version and hash with one vector per face.
private final class FakeVectorProducer: FaceVectorProducing, @unchecked Sendable {
    let manifest = ModelManifest.openCVSFace2021December
    let gate: ProducerHoldGate?
    let trace: ProducerTrace
    let duringProduce: @Sendable () -> Void
    /// Face offsets that get a vector; the rest are ineligible (for example unmatched or misaligned).
    let eligible: Set<Int>?
    init(gate: ProducerHoldGate? = nil, trace: ProducerTrace = ProducerTrace(), eligible: Set<Int>? = nil,
         duringProduce: @escaping @Sendable () -> Void = {}) {
        self.gate = gate; self.trace = trace; self.eligible = eligible; self.duringProduce = duringProduce
    }
    var calls: Int { trace.count("produce-entered") }
    func produce(_ request: ScanEnrichmentRequest, progress: @escaping ScanEnrichmentProgress) async throws -> FaceVectorProduction {
        trace.append("produce-entered")
        duringProduce()
        if let gate { await gate.enter() }
        let vectors = Dictionary(uniqueKeysWithValues: request.photo.analysis.faces.enumerated().compactMap { offset, face in
            eligible?.contains(offset) == false ? nil
                : (face.id, EmbeddingVector(modelIdentifier: manifest.identifier, values: (0..<128).map { $0 == offset ? 1 : 0 }))
        })
        trace.append("produce-returned")
        return FaceVectorProduction(photoID: request.photo.id, contentVersion: request.photo.contentVersion,
                                    contentHash: request.contentHash, vectors: vectors)
    }
}

/// Lock-protected mutable value for injected clocks and thermal state.
private final class Box<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private struct JobFixture {
    static let source = "job-source"
    static let hash = String(repeating: "c", count: 64)
    let catalog: CatalogRepository
    let photo: PhotoIdentity
    let index: InMemoryFaceVectorIndex
    let resources: FaceJobResources
    let thermal: Box<ProcessInfo.ThermalState>
    var request: ScanEnrichmentRequest {
        ScanEnrichmentRequest(photo: photo, entry: SourceEntry(relativePath: photo.relativePath),
                              sourceIdentity: Self.source, bytes: Data(), contentHash: Self.hash)
    }
    var keys: [FaceKey] { photo.analysis.faces.map { FaceKey(photo: photo, face: $0) } }

    static func make(_ test: XCTestCase) async throws -> JobFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AFITCJobs-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let catalog = try CatalogRepository(directory: root.appendingPathComponent("Catalog"),
                                            cacheDirectory: root.appendingPathComponent("Cache"))
        _ = try await catalog.acquireSource(identity: source, confirmed: true)
        let faces = [FaceGeometry(rectangle: [0.05, 0.1, 0.2, 0.3], landmarks: []),
                     FaceGeometry(rectangle: [0.6, 0.1, 0.2, 0.3], landmarks: [])]
        let photo = PhotoIdentity(relativePath: "job.jpg", analysis: FaceAnalysisState(status: .successful, faces: faces),
                                  contentHash: hash)
        try await catalog.save(photo, progress: ScanProgress())
        let thermal = Box(ProcessInfo.ThermalState.nominal)
        let resources = FaceJobResources { thermal.value }
        resources.isEnabled = true
        return JobFixture(catalog: catalog, photo: photo, index: try InMemoryFaceVectorIndex(),
                          resources: resources, thermal: thermal)
    }

    func coordinator(_ producer: FaceVectorProducing, stats: FaceJobStats = FaceJobStats(),
                     clock: @escaping @Sendable () -> TimeInterval = { 0 }) -> FaceJobCoordinator {
        FaceJobCoordinator(repository: catalog, producer: producer, index: index, gate: resources, stats: stats, clock: clock)
    }

    /// Runs one held job, applies `change` while the producer is inside production, then releases.
    func heldJob(_ change: () async throws -> Void) async throws -> FaceJobCoordinator {
        let gate = ProducerHoldGate()
        let jobs = coordinator(FakeVectorProducer(gate: gate))
        let request = self.request
        let job = Task { try await jobs.enrich(request) { _ in } }
        try await gate.waitEntered()
        try await change()
        await gate.release()
        try await job.value
        return jobs
    }
}

final class FaceJobCoordinatorTests: XCTestCase {
    func testContentChangeDuringJobDiscardsResult() async throws {
        let f = try await JobFixture.make(self)
        let jobs = try await f.heldJob {
            var changed = f.photo; changed.contentHash = String(repeating: "d", count: 64)
            try await f.catalog.save(changed, progress: ScanProgress())
        }
        XCTAssertEqual(f.index.count, 0, "vectors from replaced bytes are never indexed")
        let stats = jobs.stats.snapshot
        XCTAssertEqual(stats.discarded, 1); XCTAssertEqual(stats.indexedPhotos, 0); XCTAssertEqual(stats.failed, 0)
    }

    func testManualStateChangeDuringJobDiscardsResult() async throws {
        let f = try await JobFixture.make(self)
        let jobs = try await f.heldJob { _ = try await f.catalog.applyDecision(.notPerson(face: f.keys[0])) }
        XCTAssertEqual(f.index.count, 0, "a manual decision during production invalidates the whole photo")
        XCTAssertEqual(jobs.stats.snapshot.discarded, 1); XCTAssertEqual(jobs.stats.snapshot.indexedFaces, 0)
        let state = try await f.catalog.peopleSnapshot().faces.first { $0.key == f.keys[0] }?.state
        XCTAssertEqual(state?.notPerson, true, "the human decision itself is untouched")
    }

    func testInvalidateDuringJobPublishesNothing() async throws {
        let f = try await JobFixture.make(self)
        let before = f.index.epoch
        // The gate stays open: only the index epoch can stop this publication.
        let jobs = try await f.heldJob { f.index.invalidate() }
        XCTAssertGreaterThan(f.index.epoch, before, "invalidate bumps the epoch")
        XCTAssertNil(f.resources.pauseReason())
        XCTAssertEqual(f.index.count, 0, "a job that started before invalidate never publishes after it")
        let stats = jobs.stats.snapshot
        XCTAssertEqual(stats.discarded, 1); XCTAssertEqual(stats.indexedPhotos, 0)
        XCTAssertEqual(stats.indexedFaces, 0); XCTAssertEqual(stats.failed, 0)
        try await jobs.enrich(f.request) { _ in }
        XCTAssertEqual(f.index.count, 2, "the next job reads the new epoch and publishes normally")
    }

    func testDisabledGateAndThermalPauseSkipWithoutFailure() async throws {
        XCTAssertEqual(FaceJobResources().pauseReason(), .disabled, "evaluation jobs default off")
        let f = try await JobFixture.make(self)
        let producer = FakeVectorProducer()
        let messages = Box<[String]>([])
        let record: ScanEnrichmentProgress = { message in messages.value.append(message) }
        f.resources.isEnabled = false
        try await f.coordinator(producer).enrich(f.request, progress: record)
        f.resources.isEnabled = true
        for state in [ProcessInfo.ThermalState.serious, .critical] {
            f.thermal.value = state
            try await f.coordinator(producer).enrich(f.request, progress: record)
        }
        f.thermal.value = .fair
        XCTAssertNil(f.resources.pauseReason())
        f.resources.latchMemoryWarning()
        let jobs = f.coordinator(producer)
        try await jobs.enrich(f.request, progress: record)
        XCTAssertEqual(messages.value, ["Suggestion jobs are off.", "Suggestion jobs paused: device is warm",
                                        "Suggestion jobs paused: device is warm", "Suggestion jobs paused: memory is low"])
        XCTAssertEqual(jobs.stats.snapshot.paused, 1); XCTAssertEqual(jobs.stats.snapshot.lastPauseReason, .memory)
        f.resources.clearMemoryWarning()
        XCTAssertNil(f.resources.pauseReason())
        XCTAssertEqual(producer.calls, 0); XCTAssertEqual(f.index.count, 0)

        // Through the real serial scan: a paused job is visible stage text, never a failure.
        let h = try await ProducerHarness.make(self)
        f.thermal.value = .serious
        let scanJobs = FaceJobCoordinator(repository: h.catalog, producer: producer, index: f.index, gate: f.resources)
        let seen = Box<[String]>([])
        let source = EnrichmentSource(data: h.bytes, entries: [SourceEntry(relativePath: "warm.jpg")])
        let result = await ScanCoordinator(repository: h.catalog).scan(
            source: source, detector: EnrichmentDetector(), confirmedSource: true, enrichment: scanJobs) { progress, _ in
            if let message = progress.message { seen.value.append(message) }
        }
        XCTAssertEqual(result.phase, .completed); XCTAssertEqual(result.failed, 0); XCTAssertEqual(result.processed, 1)
        XCTAssertTrue(seen.value.contains(FaceJobPauseReason.thermal.rawValue))
        XCTAssertEqual(producer.calls, 0); XCTAssertEqual(f.index.count, 0)
        let saved = try await h.catalog.photos()
        XCTAssertEqual(saved.map(\.analysis.status), [.successful], "accepted analysis is unchanged")
    }

    func testCancellationDrainsThenPublishesNothing() async throws {
        let f = try await JobFixture.make(self)
        let gate = ProducerHoldGate(), trace = ProducerTrace()
        let jobs = f.coordinator(FakeVectorProducer(gate: gate, trace: trace))
        let request = f.request
        let job = Task {
            do { try await jobs.enrich(request) { _ in }; trace.append("enrich-returned") }
            catch is CancellationError { trace.append("enrich-cancelled") }
            catch { trace.append("enrich-failed") }
        }
        try await gate.waitEntered()
        job.cancel()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(trace.index("enrich-cancelled"), "cancellation waits for the producer's actual return")
        await gate.release()
        await job.value
        let returned = try XCTUnwrap(trace.index("produce-returned"))
        XCTAssertLessThan(returned, try XCTUnwrap(trace.index("enrich-cancelled")))
        XCTAssertNil(trace.index("enrich-returned"))
        XCTAssertEqual(f.index.count, 0); XCTAssertEqual(jobs.stats.snapshot.indexedPhotos, 0)
    }

    func testWithinSessionRescanSkipsInferenceWhenIndexed() async throws {
        let f = try await JobFixture.make(self)
        let producer = FakeVectorProducer()
        let jobs = f.coordinator(producer)
        try await jobs.enrich(f.request) { _ in }
        XCTAssertEqual(producer.calls, 1); XCTAssertEqual(f.index.count, 2)
        let held = f.index.snapshot().keys
        XCTAssertEqual(Set(held.map(\.face)), Set(f.keys))
        XCTAssertTrue(held.allSatisfy { $0.contentHash == JobFixture.hash && $0.modelIdentifier == producer.manifest.identifier })
        try await jobs.enrich(f.request) { _ in }
        XCTAssertEqual(producer.calls, 1, "every face already indexed for this hash and model")
        XCTAssertEqual(jobs.stats.snapshot.skippedAlreadyIndexed, 1)
        f.index.invalidate()
        try await jobs.enrich(f.request) { _ in }
        XCTAssertEqual(producer.calls, 2, "the skip comes from the index, not a one-shot flag")
        XCTAssertEqual(f.index.count, 2); XCTAssertEqual(jobs.stats.snapshot.indexedPhotos, 2)
    }

    func testPhotoWithIneligibleFaceIsNotReinferredWithinSession() async throws {
        let f = try await JobFixture.make(self)
        let partial = FakeVectorProducer(eligible: [0])
        let jobs = f.coordinator(partial)
        try await jobs.enrich(f.request) { _ in }
        try await jobs.enrich(f.request) { _ in }
        XCTAssertEqual(partial.calls, 1, "an attempted photo is not re-inferred for its ineligible face")
        XCTAssertEqual(f.index.count, 1)
        var stats = jobs.stats.snapshot
        XCTAssertEqual(stats.indexedPhotos, 1); XCTAssertEqual(stats.indexedFaces, 1); XCTAssertEqual(stats.skippedAlreadyIndexed, 1)

        // A photo with faces but no eligible vector is attempted once and never counted as indexed.
        f.index.invalidate()
        let none = FakeVectorProducer(eligible: [])
        let empty = f.coordinator(none)
        try await empty.enrich(f.request) { _ in }
        try await empty.enrich(f.request) { _ in }
        stats = empty.stats.snapshot
        XCTAssertEqual(none.calls, 1); XCTAssertEqual(f.index.count, 0)
        XCTAssertEqual(stats.indexedPhotos, 0); XCTAssertEqual(stats.indexedFaces, 0)
        XCTAssertEqual(stats.skippedNoVectors, 1); XCTAssertEqual(stats.skippedAlreadyIndexed, 1)

        // The attempt is dropped with the vectors, so the next session-equivalent pass infers again.
        f.index.invalidate()
        try await jobs.enrich(f.request) { _ in }
        XCTAssertEqual(partial.calls, 2); XCTAssertEqual(f.index.count, 1)
    }

    func testJobStatsRecordDurationsOnly() async throws {
        let f = try await JobFixture.make(self)
        let now = Box<TimeInterval>(100)
        let producer = FakeVectorProducer { now.value += 0.25 }
        let jobs = f.coordinator(producer, clock: { now.value })
        try await jobs.enrich(f.request) { _ in }
        try await jobs.enrich(f.request) { _ in }
        var snapshot = jobs.stats.snapshot
        XCTAssertEqual(snapshot.durations, [0.25], "skipped rescans record no duration")
        XCTAssertEqual(snapshot.p50, 0.25); XCTAssertEqual(snapshot.p95, 0.25)
        XCTAssertEqual(snapshot.indexedPhotos, 1); XCTAssertEqual(snapshot.indexedFaces, 2)
        XCTAssertEqual(snapshot.skippedAlreadyIndexed, 1); XCTAssertEqual(snapshot.skippedNoFaces, 0)

        // A photo with no detected faces is neither inferred nor counted as already indexed.
        let empty = PhotoIdentity(relativePath: "empty.jpg", analysis: FaceAnalysisState(status: .successful, faces: []),
                                  contentHash: String(repeating: "e", count: 64))
        try await f.catalog.save(empty, progress: ScanProgress())
        let emptyRequest = ScanEnrichmentRequest(photo: empty, entry: SourceEntry(relativePath: empty.relativePath),
                                                 sourceIdentity: JobFixture.source, bytes: Data(), contentHash: empty.contentHash!)
        try await jobs.enrich(emptyRequest) { _ in }
        snapshot = jobs.stats.snapshot
        XCTAssertEqual(producer.calls, 1, "zero-face photos never reach inference")
        XCTAssertEqual(snapshot.skippedNoFaces, 1); XCTAssertEqual(snapshot.skippedAlreadyIndexed, 1)
        XCTAssertEqual(snapshot.durations, [0.25]); XCTAssertEqual(snapshot.discarded, 0)

        let rolling = FaceJobStats()
        XCTAssertNil(rolling.snapshot.p50)
        for value in 1...60 { rolling.record(duration: Double(value)) }
        snapshot = rolling.snapshot
        XCTAssertEqual(snapshot.durations, (11...60).map(Double.init), "only the last 50 are kept")
        XCTAssertEqual(snapshot.p50, 35); XCTAssertEqual(snapshot.p95, 58)

        // Only numeric fields and the fixed pause enum: no names, paths, identifiers or vectors.
        let allowed: Set<String> = ["Int", "Optional<Double>", "Array<Double>", "Optional<FaceJobPauseReason>"]
        let fields = Mirror(reflecting: jobs.stats.snapshot).children.map { ($0.label ?? "?", String(describing: type(of: $0.value))) }
        XCTAssertEqual(fields.count, 13)
        for (label, type) in fields { XCTAssertTrue(allowed.contains(type), "unexpected stats field \(label): \(type)") }
    }
}
