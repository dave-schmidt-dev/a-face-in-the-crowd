@testable import AFITCCore
@testable import AFITCRuntime
import Foundation
import XCTest

private struct HeldPreparationLoader: FacePipelineModelLoader {
    let gate: ProducerHoldGate
    let loader: ProducerFakeLoader
    func load() async throws -> FacePipelineModels {
        await gate.enter()
        return try await loader.load()
    }
}

/// Causal analysis-read admission, resource readiness and explicit retry contracts.
final class PersistentFaceAdmissionTests: XCTestCase {
    private let manifest = ModelManifest.openCVSFace2021December
    private func scanner(_ repository: CatalogRepository) -> ScanCoordinator { ScanCoordinator(repository: repository) }
    private func entry(_ bytes: Data) -> SourceEntry {
        SourceEntry(relativePath: "one.jpg", metadata: SourceMetadata(revision: "r1", size: bytes.count))
    }

    private func trustedPhoto(_ h: ProducerHarness) async throws -> PhotoIdentity {
        var photo = try await h.savePhoto(rects: [ProducerHarness.primaryRect], path: "one.jpg")
        let lease = try await h.catalog.acquireSource(identity: ProducerHarness.sourceIdentity, confirmed: true)
        photo.previewPath = try await h.catalog.storePreview(JPEGPreviewDecoder.jpeg(JPEGPreviewDecoder.decode(h.bytes)),
                                                             id: photo.id, generation: "1-\(lease)", lease: lease)
        try await h.catalog.save(photo, progress: ScanProgress())
        return photo
    }

    func testZeroFaceDurableJobRecordsEmptySuccessWithoutModelWork() async throws {
        let h = try await ProducerHarness.make(self)
        let photo = try await h.savePhoto(rects: [])
        let loader = ProducerFakeLoader(yuNet: ProducerYuNetBackend(), sFace: ProducerSFaceBackend())
        let persistent = h.persistent(loader)
        let resources = FaceJobResources(); resources.isEnabled = true
        let job = FaceJobCoordinator(repository: h.catalog,
            producer: RuntimeFaceVectorProducer(enrichment: persistent, store: h.store),
            index: try InMemoryFaceVectorIndex(), gate: resources)
        try await job.enrich(h.request(photo)) { _ in }
        let status = try await h.catalog.photoAnalysisStatus(photoID: photo.id, contentVersion: photo.contentVersion,
                                                             contentHash: h.hash, manifest: manifest)
        XCTAssertEqual(status, .emptySuccess)
        let admitted = await job.needsAdmittedRead(photo)
        XCTAssertFalse(admitted)
        XCTAssertEqual(loader.loads.value, 0)
    }

    func testReboundSourcePrunesAllStaleRowsBeforeCapacityAdmission() async throws {
        let h = try await ProducerHarness.make(self)
        let first = try await h.savePhoto(rects: [ProducerHarness.primaryRect], path: "first.jpg")
        let second = try await h.savePhoto(rects: [ProducerHarness.primaryRect], path: "second.jpg")
        var values = [Float](repeating: 0, count: 128); values[0] = 1
        let vector = EmbeddingVector(modelIdentifier: manifest.identifier, values: values)
        for photo in [first, second] {
            let fence = try await h.catalog.captureFaceAnalysisPersistenceFence(photo: photo, sourceIdentity: ProducerHarness.sourceIdentity)
            _ = try await h.catalog.saveFaceAnalysisBatch(fence: fence, verifiedContentHash: h.hash,
                vectors: [(photo.analysis.faces[0].id, vector)], manifest: manifest)
        }
        _ = try await h.catalog.acquireSource(identity: "source-new", confirmed: true)
        let fence = try await h.catalog.captureFaceAnalysisPersistenceFence(photo: first, sourceIdentity: "source-new")
        let outcome = try await h.catalog.saveFaceAnalysisBatch(fence: fence, verifiedContentHash: h.hash,
            vectors: [(first.analysis.faces[0].id, vector)], manifest: manifest, capacity: 1)
        XCTAssertEqual(outcome, .inserted(1))
        let rows = try await h.catalog.faceVectorRows()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].photoID, first.id)
    }

    func testUnavailableModelsAdmitZeroCatchUpReads() async throws {
        let h = try await ProducerHarness.make(self)
        _ = try await trustedPhoto(h)
        var loader = ProducerFakeLoader(yuNet: ProducerYuNetBackend(), sFace: ProducerSFaceBackend())
        loader.fails = true
        let persistent = h.persistent(loader)
        for _ in 0..<2 {
            let source = EnrichmentSource(data: h.bytes, entries: [entry(h.bytes)])
            let detector = SFaceLockedCount()
            _ = await scanner(h.catalog).scan(source: source, detector: CountingDetector(calls: detector),
                                              confirmedSource: true, enrichment: persistent) { _, _ in }
            let reads = await source.reads
            XCTAssertEqual(reads, 0)
            XCTAssertEqual(detector.value, 0)
        }
        XCTAssertEqual(loader.loads.value, 1, "failed readiness is retained for this scan producer")
        XCTAssertEqual(loader.sFace.calls, 0)
    }

    func testPauseOrCancellationDuringModelPreparationAdmitsNoRead() async throws {
        for canceled in [false, true] {
            let h = try await ProducerHarness.make(self)
            let photo = try await trustedPhoto(h)
            let gate = ProducerHoldGate(), resources = FaceJobResources()
            resources.isEnabled = true
            let loader = HeldPreparationLoader(gate: gate, loader: ProducerFakeLoader(yuNet: ProducerYuNetBackend(), sFace: ProducerSFaceBackend()))
            let producer = TransientFaceEmbeddingProducer(repository: h.catalog, store: h.store,
                token: h.store.begin(operationID: UUID(), sessionEpoch: 8), loader: loader)
            let persistent = PersistentFaceAnalysisProducer(producer: producer, repository: h.catalog, store: h.store,
                                                             gate: resources)
            let run = Task { await persistent.needsAdmittedRead(photo) }
            try await gate.waitEntered()
            if canceled { run.cancel() } else { resources.latchMemoryWarning() }
            await gate.release()
            let admitted = await run.value
            XCTAssertFalse(admitted)
            XCTAssertEqual(loader.loader.sFace.calls, 0)
        }
    }

    func testFailedAnalysisDoesNotInferAgainFromOrdinaryReadBytes() async throws {
        let h = try await ProducerHarness.make(self)
        let photo = try await h.savePhoto(rects: [ProducerHarness.primaryRect])
        let fence = try await h.catalog.captureFaceAnalysisPersistenceFence(photo: photo, sourceIdentity: ProducerHarness.sourceIdentity)
        _ = try await h.catalog.saveFaceAnalysisBatch(fence: fence, verifiedContentHash: h.hash, vectors: [], manifest: manifest,
                                                      status: .failed)
        let loader = ProducerFakeLoader(yuNet: ProducerYuNetBackend(), sFace: ProducerSFaceBackend())
        let persistent = h.persistent(loader)
        try await persistent.enrich(h.request(photo)) { _ in }
        XCTAssertEqual(loader.loads.value, 0)
        XCTAssertEqual(loader.sFace.calls, 0)
    }

    func testExplicitRetryAdmitsOneAttemptAndLeavesManualIdentityIntact() async throws {
        for status in [PhotoAnalysisStatus.failed, .paused, .capacityFull] {
            let h = try await ProducerHarness.make(self)
            let photo = try await h.savePhoto(rects: [ProducerHarness.primaryRect])
            let key = FaceKey(photo: photo, face: photo.analysis.faces[0])
            _ = try await h.catalog.applyDecision(.name(face: key, displayName: "Fictional A"))
            let before = try await h.catalog.peopleSnapshot().faces.first { $0.key == key }?.state
            let fence = try await h.catalog.captureFaceAnalysisPersistenceFence(photo: photo, sourceIdentity: ProducerHarness.sourceIdentity)
            _ = try await h.catalog.saveFaceAnalysisBatch(fence: fence, verifiedContentHash: h.hash, vectors: [], manifest: manifest, status: status)
            let loader = ProducerFakeLoader(yuNet: ProducerYuNetBackend(), sFace: ProducerSFaceBackend())
            let persistent = h.persistent(loader)
            let held = await persistent.needsAdmittedRead(photo)
            XCTAssertFalse(held)
            try await persistent.enrich(h.request(photo)) { _ in }
            XCTAssertEqual(loader.loads.value, 0)
            try await h.catalog.admitFaceAnalysisRetry(photo: photo, manifest: manifest)
            let admitted = await persistent.needsAdmittedRead(photo)
            XCTAssertTrue(admitted)
            try await persistent.enrich(h.request(photo)) { _ in }
            let repeated = await persistent.needsAdmittedRead(photo)
            XCTAssertFalse(repeated)
            XCTAssertEqual(loader.sFace.calls, 1)
            let after = try await h.catalog.peopleSnapshot().faces.first { $0.key == key }?.state
            XCTAssertEqual(after, before)
        }
    }

    func testOldSourceSuppressionDoesNotSuppressReboundSourceGeneration() async throws {
        let h = try await ProducerHarness.make(self)
        let photo = try await h.savePhoto(rects: [ProducerHarness.primaryRect])
        let key = FaceKey(photo: photo, face: photo.analysis.faces[0])
        try await h.catalog.suppressFace(key: key, photoID: photo.id, contentVersion: photo.contentVersion,
                                         contentHash: h.hash, sourceBinding: ProducerHarness.sourceIdentity)
        _ = try await h.catalog.acquireSource(identity: "source-new", confirmed: true)
        let loader = ProducerFakeLoader(yuNet: ProducerYuNetBackend(), sFace: ProducerSFaceBackend())
        let persistent = h.persistent(loader)
        let request = ScanEnrichmentRequest(photo: photo, entry: SourceEntry(relativePath: photo.relativePath),
                                           sourceIdentity: "source-new", bytes: h.bytes, contentHash: h.hash)
        try await persistent.enrich(request) { _ in }
        let rows = try await h.catalog.currentDurableFaceVectors(manifest: manifest)
        XCTAssertEqual(rows.map(\.face), [key])
        XCTAssertEqual(loader.sFace.calls, 1)
    }

    func testModelsUnavailableLeavesAnalysisMissingForLaterRetry() async throws {
        let h = try await ProducerHarness.make(self)
        let photo = try await h.savePhoto(rects: [ProducerHarness.primaryRect])
        var loader = ProducerFakeLoader(yuNet: ProducerYuNetBackend(), sFace: ProducerSFaceBackend())
        loader.fails = true
        let persistent = h.persistent(loader)
        await expectProducerError(.modelsUnavailable) { try await persistent.enrich(h.request(photo)) { _ in } }
        let status = try await h.catalog.photoAnalysisStatus(photoID: photo.id, contentVersion: photo.contentVersion,
                                                             contentHash: h.hash, manifest: manifest)
        XCTAssertNil(status, "unavailable models record nothing; the runtime retry is honest")
        let admitted = try await h.catalog.needsAdmittedAnalysisRead(photo: photo, manifest: manifest)
        XCTAssertTrue(admitted, "the catch-up read retries once the runtime is ready")
    }

    func testFailedAndCapacityFullAreExplicitRetryStates() async throws {
        let h = try await ProducerHarness.make(self)
        let photo = try await h.savePhoto(rects: [ProducerHarness.primaryRect])
        let fence = try await h.catalog.captureFaceAnalysisPersistenceFence(photo: photo,
                                                                             sourceIdentity: ProducerHarness.sourceIdentity)
        try await h.catalog.saveFaceAnalysisBatch(fence: fence, verifiedContentHash: fence.contentHash,
                                                  vectors: [], manifest: manifest, status: .failed, reason: "decode error")
        var reused = try await h.catalog.satisfiesAnalysisReuse(photo: photo, manifest: manifest)
        XCTAssertFalse(reused)
        var admitted = try await h.catalog.needsAdmittedAnalysisRead(photo: photo, manifest: manifest)
        XCTAssertFalse(admitted, "failure is an explicit retry state, never a repeated source read")

        let empty = try await h.savePhoto(rects: [], path: "empty.jpg")
        let emptyFence = try await h.catalog.captureFaceAnalysisPersistenceFence(photo: empty,
                                                                                  sourceIdentity: ProducerHarness.sourceIdentity)
        try await h.catalog.saveFaceAnalysisBatch(fence: emptyFence, verifiedContentHash: emptyFence.contentHash,
                                                  vectors: [], manifest: manifest, status: .capacityFull)
        reused = try await h.catalog.satisfiesAnalysisReuse(photo: empty, manifest: manifest)
        XCTAssertFalse(reused)
        admitted = try await h.catalog.needsAdmittedAnalysisRead(photo: empty, manifest: manifest)
        XCTAssertFalse(admitted, "capacity-full is an explicit retry state")
    }

    func testPausedSuggestionGateAdmitsNoCatchUpRead() async throws {
        let h = try await ProducerHarness.make(self)
        var photo = try await h.savePhoto(rects: [ProducerHarness.primaryRect])
        let lease = try await h.catalog.acquireSource(identity: ProducerHarness.sourceIdentity, confirmed: true)
        let preview = try JPEGPreviewDecoder.jpeg(JPEGPreviewDecoder.decode(h.bytes))
        photo.previewPath = try await h.catalog.storePreview(preview, id: photo.id,
                                                             generation: "1-\(lease)", lease: lease)
        try await h.catalog.save(photo, progress: ScanProgress())

        let resources = FaceJobResources()
        resources.isEnabled = true
        resources.latchMemoryWarning()
        let index = try InMemoryFaceVectorIndex()
        let persistent = h.persistent(ProducerFakeLoader(yuNet: ProducerYuNetBackend(), sFace: ProducerSFaceBackend()))
        let runtime = RuntimeFaceVectorProducer(enrichment: persistent, store: h.store)
        let job = FaceJobCoordinator(repository: h.catalog, producer: runtime, index: index, gate: resources)
        let paused = await job.needsAdmittedRead(photo)
        XCTAssertFalse(paused, "a paused gate never starts source work")
        resources.clearMemoryWarning()
        let ready = await job.needsAdmittedRead(photo)
        XCTAssertTrue(ready, "once the gate reopens the missing analysis is admitted")
    }
}
