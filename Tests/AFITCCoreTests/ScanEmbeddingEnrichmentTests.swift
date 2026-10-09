@testable import AFITCCore
@testable import AFITCRuntime
import Foundation
import XCTest

/// Fake read-only source recording every open/read/close in the shared causal trace.
actor EnrichmentSource: PhotoSource {
    let data: Data
    let entries: [SourceEntry]
    let trace: ProducerTrace
    private var position = 0
    private(set) var reads = 0
    let sourceID: String?
    init(data: Data, entries: [SourceEntry], trace: ProducerTrace = ProducerTrace(),
         sourceID: String? = ProducerHarness.sourceIdentity) {
        self.data = data; self.entries = entries; self.trace = trace; self.sourceID = sourceID
    }
    func identity() async throws -> String? { sourceID }
    func open() async throws { position = 0; trace.append("open") }
    func next() async throws -> SourceEntry? {
        guard position < entries.count else { return nil }
        defer { position += 1 }
        return entries[position]
    }
    func read(_ entry: SourceEntry) async throws -> Data { reads += 1; trace.append("read"); return data }
    func close() async { trace.append("close") }
}

/// Fake Vision step: accepted analysis with one face that overlaps the fake YuNet face.
struct EnrichmentDetector: DetectionProvider {
    var faces = 1
    func process(_ data: Data, contentVersion: Int) async throws -> ProcessedPreview {
        let image = try JPEGPreviewDecoder.decode(data)
        let geometry = (0..<faces).map { _ in FaceGeometry(rectangle: ProducerHarness.primaryRect, landmarks: []) }
        return ProcessedPreview(jpeg: try JPEGPreviewDecoder.jpeg(image), analysis: FaceAnalysisState(
            status: .successful, detectorVersion: ProducerHarness.detectorVersion, contentVersion: contentVersion,
            faces: geometry))
    }
}

/// Records requests; optionally holds or fails after recording.
final class RecordingEnrichment: ScanEnrichment, @unchecked Sendable {
    let gate: ProducerHoldGate?
    let fails: Bool
    let trace: ProducerTrace
    private let lock = NSLock()
    private var stored: [ScanEnrichmentRequest] = []
    init(gate: ProducerHoldGate? = nil, fails: Bool = false, trace: ProducerTrace = ProducerTrace()) {
        self.gate = gate; self.fails = fails; self.trace = trace
    }
    var requests: [ScanEnrichmentRequest] { lock.withLock { stored } }
    func enrich(_ request: ScanEnrichmentRequest, progress: @escaping ScanEnrichmentProgress) async throws {
        lock.withLock { stored.append(request) }
        trace.append("enrich-entered")
        if let gate { await gate.enter() }
        trace.append("enrich-returned")
        if fails { throw TransientFaceEmbeddingError.pipelineFailed }
    }
}

final class ScanEmbeddingEnrichmentTests: XCTestCase {
    private func scanner(_ h: ProducerHarness) -> ScanCoordinator { ScanCoordinator(repository: h.catalog) }

    func testEnrichmentReusesTheSingleVerifiedReadBytesHashEntryAndSource() async throws {
        let h = try await ProducerHarness.make(self)
        let entry = SourceEntry(relativePath: "one.jpg", metadata: SourceMetadata(revision: "r1", size: h.bytes.count))
        let source = EnrichmentSource(data: h.bytes, entries: [entry])
        let enrichment = RecordingEnrichment()
        let result = await scanner(h).scan(source: source, detector: EnrichmentDetector(), confirmedSource: true,
                                           enrichment: enrichment) { _, _ in }
        XCTAssertEqual(result.phase, .completed)
        let reads = await source.reads
        XCTAssertEqual(reads, 1, "enrichment must not trigger a second read")
        let request = try XCTUnwrap(enrichment.requests.first)
        XCTAssertEqual(enrichment.requests.count, 1)
        let savedPhotos = try await h.catalog.photos()
        let saved = try XCTUnwrap(savedPhotos.first)
        XCTAssertEqual(request.bytes, h.bytes); XCTAssertEqual(request.contentHash, h.hash)
        XCTAssertEqual(saved.contentHash, h.hash); XCTAssertEqual(request.photo.id, saved.id)
        XCTAssertEqual(request.photo.analysis, saved.analysis); XCTAssertEqual(request.entry, entry)
        XCTAssertEqual(request.sourceIdentity, ProducerHarness.sourceIdentity)
    }

    func testTrustedFastPathMalformedBytesAndNilDefaultMakeZeroCallbacks() async throws {
        let h = try await ProducerHarness.make(self)
        let entry = SourceEntry(relativePath: "one.jpg", metadata: SourceMetadata(revision: "r1", size: h.bytes.count))
        let first = await scanner(h).scan(source: EnrichmentSource(data: h.bytes, entries: [entry]),
                                          detector: EnrichmentDetector(), confirmedSource: true) { _, _ in }
        XCTAssertEqual(first.phase, .completed, "nil default keeps the existing scan behavior")
        let trusted = EnrichmentSource(data: h.bytes, entries: [entry])
        let enrichment = RecordingEnrichment()
        let second = await scanner(h).scan(source: trusted, detector: EnrichmentDetector(), confirmedSource: true,
                                           enrichment: enrichment) { _, _ in }
        XCTAssertEqual(second.phase, .completed)
        let reads = await trusted.reads
        XCTAssertEqual(reads, 0); XCTAssertTrue(enrichment.requests.isEmpty, "no read bytes, no callback")

        let malformed = EnrichmentSource(data: Data("not a jpeg".utf8), entries: [SourceEntry(relativePath: "bad.jpg")])
        _ = await scanner(h).scan(source: malformed, detector: EnrichmentDetector(), confirmedSource: true,
                                  enrichment: enrichment) { _, _ in }
        XCTAssertTrue(enrichment.requests.isEmpty, "skipped analysis is never enriched")
    }

    func testAcceptedPhotoIsSavedAndPublishedBeforeHeldCallback() async throws {
        let h = try await ProducerHarness.make(self)
        let gate = ProducerHoldGate(), trace = ProducerTrace()
        let enrichment = RecordingEnrichment(gate: gate, trace: trace)
        let source = EnrichmentSource(data: h.bytes, entries: [SourceEntry(relativePath: "one.jpg")], trace: trace)
        let scan = Task {
            await self.scanner(h).scan(source: source, detector: EnrichmentDetector(), confirmedSource: true,
                                       enrichment: enrichment) { progress, photo in
                if photo?.analysis.status == .successful, photo?.previewPath != nil { trace.append("published-accepted") }
                if progress.phase == .completed { trace.append("finish") }
            }
        }
        try await gate.waitEntered()
        let accepted = try XCTUnwrap(trace.index("published-accepted"))
        XCTAssertLessThan(accepted, try XCTUnwrap(trace.index("enrich-entered")))
        let saved = try await h.catalog.photos()
        XCTAssertEqual(saved.map(\.analysis.status), [.successful], "accepted analysis durable before callback")
        XCTAssertNil(trace.index("close")); XCTAssertNil(trace.index("finish"))
        await gate.release()
        let result = await scan.value
        XCTAssertEqual(result.phase, .completed)
        XCTAssertLessThan(try XCTUnwrap(trace.index("enrich-returned")), try XCTUnwrap(trace.index("close")))
    }

    func testCallbackFailurePreservesAcceptedAnalysisAndManualStateAndReportsUnavailable() async throws {
        let h = try await ProducerHarness.make(self)
        let entry = SourceEntry(relativePath: "one.jpg")
        _ = await scanner(h).scan(source: EnrichmentSource(data: h.bytes, entries: [entry]),
                                  detector: EnrichmentDetector(), confirmedSource: true) { _, _ in }
        let firstPhotos = try await h.catalog.photos()
        let photo = try XCTUnwrap(firstPhotos.first)
        let key = FaceKey(photo: photo, face: photo.analysis.faces[0])
        _ = try await h.catalog.applyDecision(.name(face: key, displayName: "Pat"))
        let before = try await h.catalog.peopleSnapshot().faces.first { $0.key == key }?.state
        XCTAssertNotNil(before?.personID)

        let messages = ProducerMessages(), enrichment = RecordingEnrichment(fails: true)
        let result = await scanner(h).scan(source: EnrichmentSource(data: h.bytes, entries: [entry]),
                                           detector: EnrichmentDetector(), confirmedSource: true,
                                           enrichment: enrichment) { progress, _ in
            if let message = progress.message { messages.append(message) }
        }
        XCTAssertEqual(enrichment.requests.count, 1)
        XCTAssertEqual(result.phase, .completed); XCTAssertEqual(result.failed, 0)
        XCTAssertTrue(messages.values.contains("Face details unavailable for this photo. Accepted analysis is unchanged."))
        let afterPhotos = try await h.catalog.photos()
        let after = try XCTUnwrap(afterPhotos.first)
        XCTAssertEqual(after.analysis, photo.analysis); XCTAssertEqual(after.contentVersion, photo.contentVersion)
        let state = try await h.catalog.peopleSnapshot().faces.first { $0.key == key }?.state
        XCTAssertEqual(state, before)
    }

    func testProducerStageProgressReachesExistingScanSurfaceAndStopsAfterCancelRequest() async throws {
        let h = try await ProducerHarness.make(self)
        let trace = ProducerTrace()
        let producer = h.producer(ProducerFakeLoader(yuNet: ProducerYuNetBackend(), sFace: ProducerSFaceBackend()))
        let source = EnrichmentSource(data: h.bytes, entries: [SourceEntry(relativePath: "one.jpg")], trace: trace)
        let result = await scanner(h).scan(source: source, detector: EnrichmentDetector(), confirmedSource: true,
                                           enrichment: producer) { progress, photo in
            guard photo == nil, let message = progress.message else { return }
            trace.append("\(progress.phase.rawValue)|\(progress.discovered)|\(progress.processed)|\(message)")
        }
        XCTAssertEqual(result.phase, .completed)
        let close = try XCTUnwrap(trace.index("close"))
        for stage in ["Finding face details for this photo.", "Computing face details for face 1 of 1.",
                      "Face details ready for 1 of 1 detected faces in this photo."] {
            let index = try XCTUnwrap(trace.index("processing|1|1|\(stage)"), stage)
            XCTAssertLessThan(index, close, "stage text reaches the existing scan surface before close")
        }
        XCTAssertNotNil(h.store.latestBatch)

        // An explicit cancel request owns the surface; later producer stages cannot overwrite it.
        let held = try await ProducerHarness.make(self)
        let gate = ProducerHoldGate(), events = ProducerTrace()
        let heldProducer = held.producer(ProducerFakeLoader(yuNet: ProducerYuNetBackend(gate: gate, trace: events),
                                                            sFace: ProducerSFaceBackend(trace: events)))
        let coordinator = scanner(held)
        let scan = Task {
            await coordinator.scan(source: EnrichmentSource(data: held.bytes, entries: [SourceEntry(relativePath: "one.jpg")],
                                                            trace: events),
                                   detector: EnrichmentDetector(), confirmedSource: true, enrichment: heldProducer) { progress, photo in
                if photo == nil, let message = progress.message { events.append("\(progress.phase.rawValue)|\(message)") }
            }
        }
        try await gate.waitEntered()
        await coordinator.cancel()
        await gate.release()
        let cancelled = await scan.value
        XCTAssertEqual(cancelled.phase, .cancelled)
        let cancelling = try XCTUnwrap(events.events.firstIndex { $0.hasPrefix("cancelling|") })
        XCTAssertTrue(events.events.contains("sface-returned"), "the drained producer finished its work")
        XCTAssertFalse(events.events[cancelling...].contains { $0.hasPrefix("processing|") },
                       "no stage text after the cancel request")
    }

    func testCancellationDrainsHeldActualRuntimeThenClosesSourceThenFinishesOnce() async throws {
        let h = try await ProducerHarness.make(self)
        let trace = ProducerTrace(), gate = ProducerHoldGate()
        let yuNet = ProducerYuNetBackend(gate: gate, trace: trace)
        let producer = h.producer(ProducerFakeLoader(yuNet: yuNet, sFace: ProducerSFaceBackend(trace: trace)))
        let source = EnrichmentSource(data: h.bytes, entries: [SourceEntry(relativePath: "one.jpg"),
                                                               SourceEntry(relativePath: "two.jpg")], trace: trace)
        let scan = Task {
            let result = await self.scanner(h).scan(source: source, detector: EnrichmentDetector(), confirmedSource: true,
                                                    enrichment: producer) { progress, _ in
                if progress.phase == .cancelled { trace.append("finish") }
            }
            trace.append("returned")
            return result
        }
        try await gate.waitEntered()
        scan.cancel()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(trace.index("close"), "source stays open while the actual runtime is held")
        XCTAssertNil(trace.index("finish"))
        await gate.release()
        let result = await scan.value
        XCTAssertEqual(result.phase, .cancelled)
        let returned = try XCTUnwrap(trace.index("yunet-returned")), close = try XCTUnwrap(trace.index("close"))
        let finish = try XCTUnwrap(trace.index("finish"))
        XCTAssertLessThan(returned, close); XCTAssertLessThan(close, finish)
        XCTAssertEqual(trace.count("finish"), 1); XCTAssertEqual(trace.count("close"), 1)
        XCTAssertEqual(trace.count("read"), 1, "second entry never read after cancellation")
        XCTAssertFalse(trace.events.contains("sface-entered"))
        XCTAssertNil(h.store.latestBatch)
        let saved = try await h.catalog.photos()
        XCTAssertEqual(saved.map(\.analysis.status), [.successful], "accepted photo remains")
    }

    // MARK: targeted scans (Finish analyzes only listed photos)

    private func entries(_ names: [String], _ h: ProducerHarness) -> [SourceEntry] {
        names.map { SourceEntry(relativePath: $0, metadata: SourceMetadata(revision: "r-\($0)", size: h.bytes.count)) }
    }

    func testTargetedScanReadsEnrichesOnlyTargetsAndMarksNothingMissing() async throws {
        let h = try await ProducerHarness.make(self)
        let all = entries(["a.jpg", "b.jpg", "c.jpg"], h)
        _ = await scanner(h).scan(source: EnrichmentSource(data: h.bytes, entries: all), detector: EnrichmentDetector(),
                                  confirmedSource: true) { _, _ in }
        // b.jpg left the folder; a targeted scan must not mark it (or the unlisted a.jpg) missing.
        let source = EnrichmentSource(data: h.bytes, entries: [all[0], all[2]])
        let enrichment = RecordingEnrichment()
        var published: [String] = []
        let result = await scanner(h).scan(source: source, detector: EnrichmentDetector(), confirmedSource: true,
                                           targets: ["c.jpg"], enrichment: enrichment) { _, photo in
            if let photo { published.append(photo.relativePath) }
        }
        XCTAssertEqual(result.phase, .completed)
        XCTAssertEqual(result.discovered, 1); XCTAssertEqual(result.processed, 1)
        XCTAssertEqual(result.message, "Face analysis finished for the listed photos.")
        XCTAssertTrue(Set(published).isSubset(of: ["c.jpg"]), "no cached replay or callbacks for non-targets")
        let reads = await source.reads
        XCTAssertEqual(reads, 0, "trusted unchanged target needs no read; non-targets are never read")
        XCTAssertTrue(enrichment.requests.allSatisfy { $0.entry.relativePath == "c.jpg" })
        let saved = try await h.catalog.photos()
        XCTAssertEqual(saved.filter { $0.missing == true }.count, 0, "targeted scans never mark photos missing")

        // A changed target is read and enriched; the unlisted changed entry is not.
        let changed = [SourceEntry(relativePath: "a.jpg", metadata: SourceMetadata(revision: "new-a", size: 1)),
                       SourceEntry(relativePath: "c.jpg", metadata: SourceMetadata(revision: "new-c", size: 1))]
        let second = EnrichmentSource(data: h.bytes, entries: changed)
        let secondEnrichment = RecordingEnrichment()
        _ = await scanner(h).scan(source: second, detector: EnrichmentDetector(), confirmedSource: true,
                                  targets: ["c.jpg"], enrichment: secondEnrichment) { _, _ in }
        let secondReads = await second.reads
        XCTAssertEqual(secondReads, 1)
        XCTAssertEqual(secondEnrichment.requests.map(\.entry.relativePath), ["c.jpg"])
    }

    func testTargetedScanStopsEnumeratingAfterLastTarget() async throws {
        let h = try await ProducerHarness.make(self)
        let trace = ProducerTrace()
        let source = CountingSource(entries: entries(["a.jpg", "b.jpg", "c.jpg", "d.jpg"], h), data: h.bytes, trace: trace)
        let result = await scanner(h).scan(source: source, detector: EnrichmentDetector(), confirmedSource: true,
                                           targets: ["b.jpg"]) { _, _ in }
        XCTAssertEqual(result.phase, .completed)
        let pulled = await source.pulled
        XCTAssertEqual(pulled, 2, "enumeration stops once every target was seen")
        let saved = try await h.catalog.photos()
        XCTAssertEqual(saved.map(\.relativePath), ["b.jpg"])
    }

    func testTargetedScanLeavesCheckpointUnchangedOnCompletionAndCancellation() async throws {
        let h = try await ProducerHarness.make(self)
        let all = entries(["a.jpg", "b.jpg"], h)
        _ = await scanner(h).scan(source: EnrichmentSource(data: h.bytes, entries: all), detector: EnrichmentDetector(),
                                  confirmedSource: true) { _, _ in }
        let before = try await h.catalog.checkpoint()
        XCTAssertEqual(before?.phase, .completed)

        let changed = [SourceEntry(relativePath: "a.jpg", metadata: SourceMetadata(revision: "new-a", size: 1))]
        let done = await scanner(h).scan(source: EnrichmentSource(data: h.bytes, entries: changed), detector: EnrichmentDetector(),
                                         confirmedSource: true, targets: ["a.jpg"]) { _, _ in }
        XCTAssertEqual(done.phase, .completed)
        let afterDone = try await h.catalog.checkpoint()
        XCTAssertEqual(afterDone, before)

        let gate = ProducerHoldGate(), trace = ProducerTrace()
        let producer = h.producer(ProducerFakeLoader(yuNet: ProducerYuNetBackend(gate: gate, trace: trace),
                                                     sFace: ProducerSFaceBackend(trace: trace)))
        let coordinator = scanner(h)
        let moved = [SourceEntry(relativePath: "b.jpg", metadata: SourceMetadata(revision: "new-b", size: 1))]
        let scan = Task {
            await coordinator.scan(source: EnrichmentSource(data: h.bytes, entries: moved, trace: trace),
                                   detector: EnrichmentDetector(), confirmedSource: true, targets: ["b.jpg"],
                                   enrichment: producer) { _, _ in }
        }
        try await gate.waitEntered()
        await coordinator.cancel()
        await gate.release()
        let cancelled = await scan.value
        XCTAssertEqual(cancelled.phase, .cancelled)
        let afterCancel = try await h.catalog.checkpoint()
        XCTAssertEqual(afterCancel, before)
    }

    func testTargetedScanWithChangedSourceIdentityNeverRebindsEvenWhenConfirmed() async throws {
        let h = try await ProducerHarness.make(self)
        let all = entries(["a.jpg", "b.jpg"], h)
        _ = await scanner(h).scan(source: EnrichmentSource(data: h.bytes, entries: all), detector: EnrichmentDetector(),
                                  confirmedSource: true) { _, _ in }
        let checkpoint = try await h.catalog.checkpoint()
        let before = try await h.catalog.photos()
        for other in ["other-source", nil] as [String?] {
            let source = EnrichmentSource(data: h.bytes, entries: all, sourceID: other)
            let result = await scanner(h).scan(source: source, detector: EnrichmentDetector(), confirmedSource: true,
                                               targets: ["b.jpg"]) { _, _ in }
            XCTAssertEqual(result.phase, .failed)
            XCTAssertEqual(result.message, ScanError.sourceConfirmationRequired.message)
            let reads = await source.reads
            XCTAssertEqual(reads, 0)
        }
        // The original source still reconnects without confirmation: the binding was never rewritten.
        _ = try await h.catalog.acquireSource(identity: ProducerHarness.sourceIdentity, confirmed: false)
        let afterCheckpoint = try await h.catalog.checkpoint()
        XCTAssertEqual(afterCheckpoint, checkpoint)
        let after = try await h.catalog.photos()
        XCTAssertEqual(after, before)
    }

    func testTargetedScanReportsListedPhotosNotFoundInSource() async throws {
        let h = try await ProducerHarness.make(self)
        let all = entries(["a.jpg", "b.jpg"], h)
        _ = await scanner(h).scan(source: EnrichmentSource(data: h.bytes, entries: all), detector: EnrichmentDetector(),
                                  confirmedSource: true) { _, _ in }
        let result = await scanner(h).scan(source: EnrichmentSource(data: h.bytes, entries: [all[0]]),
                                           detector: EnrichmentDetector(), confirmedSource: true,
                                           targets: ["a.jpg", "b.jpg", "gone.jpg"]) { _, _ in }
        XCTAssertEqual(result.phase, .completed)
        XCTAssertEqual(result.failed, 2, "each listed photo never enumerated counts as failed")
        XCTAssertEqual(result.message, "Some listed photos were not found in the source folder.")
    }

    func testNilTargetsScanStillMarksUnseenPhotosMissing() async throws {
        let h = try await ProducerHarness.make(self)
        let all = entries(["a.jpg", "b.jpg"], h)
        _ = await scanner(h).scan(source: EnrichmentSource(data: h.bytes, entries: all), detector: EnrichmentDetector(),
                                  confirmedSource: true) { _, _ in }
        _ = await scanner(h).scan(source: EnrichmentSource(data: h.bytes, entries: [all[0]]), detector: EnrichmentDetector(),
                                  confirmedSource: true) { _, _ in }
        let saved = try await h.catalog.photos()
        XCTAssertEqual(saved.filter { $0.missing == true }.map(\.relativePath), ["b.jpg"])
    }
}

/// Source that counts how many entries enumeration pulled.
actor CountingSource: PhotoSource {
    let entries: [SourceEntry]
    let data: Data
    let trace: ProducerTrace
    private var position = 0
    private(set) var pulled = 0
    init(entries: [SourceEntry], data: Data, trace: ProducerTrace) { self.entries = entries; self.data = data; self.trace = trace }
    func identity() async throws -> String? { ProducerHarness.sourceIdentity }
    func open() async throws { position = 0 }
    func next() async throws -> SourceEntry? {
        guard position < entries.count else { return nil }
        defer { position += 1; pulled += 1 }
        return entries[position]
    }
    func read(_ entry: SourceEntry) async throws -> Data { data }
    func close() async {}
}
