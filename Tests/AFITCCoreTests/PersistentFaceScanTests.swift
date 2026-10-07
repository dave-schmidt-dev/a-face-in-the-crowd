@testable import AFITCCore
@testable import AFITCRuntime
import Foundation
import XCTest

extension ProducerHarness {
    /// The durable producer the App wraps for every ordinary scan.
    func persistent(_ loader: ProducerFakeLoader, operationID: UUID = UUID(), session: UInt64 = 7)
        -> PersistentFaceAnalysisProducer {
        PersistentFaceAnalysisProducer(producer: producer(loader, operationID: operationID, session: session),
                                       repository: catalog, store: store)
    }
}

/// DetectionProvider that records calls: the no-detector-rerun catch-up must never reach it.
struct CountingDetector: DetectionProvider {
    let calls: SFaceLockedCount
    func process(_ data: Data, contentVersion: Int) async throws -> ProcessedPreview {
        calls.increment()
        return try await EnrichmentDetector().process(data, contentVersion: contentVersion)
    }
}

/// SFace backend whose inference fails generically, so the producer reports pipelineFailed.
private final class FailingSFaceBackend: EmbeddingInferenceBackend, @unchecked Sendable {
    struct Boom: Error {}
    let metadata = EmbeddingRuntimeMetadata(
        inputNames: [ProducerSFaceBackend.manifest.inputName], inputShape: ProducerSFaceBackend.manifest.inputShape,
        inputElementType: .float32, outputNames: [ProducerSFaceBackend.manifest.outputName],
        outputShape: ProducerSFaceBackend.manifest.outputShape, outputElementType: .float32)
    func infer(_ input: ModelTensor) async throws -> EmbeddingVector { throw Boom() }
}

private struct FailingPipelineLoader: FacePipelineModelLoader {
    let loads = SFaceLockedCount()
    func load() async throws -> FacePipelineModels {
        loads.increment()
        return FacePipelineModels(yuNet: YuNetRuntime(backend: ProducerYuNetBackend()),
                                  sFace: FaceEmbeddingRuntime(manifest: ProducerSFaceBackend.manifest,
                                                              backend: FailingSFaceBackend()))
    }
}

/// Task 7.3: analyze once during scan and reuse thereafter. Ordinary scans persist their
/// verified analysis; trusted unchanged photos with current analysis cause zero reads and
/// zero inference; missing analysis gets exactly one admitted catch-up read that preserves
/// every existing Vision FaceKey, geometry, contentVersion and manual decision.
final class PersistentFaceScanTests: XCTestCase {
    private let manifest = ModelManifest.openCVSFace2021December

    private func scanner(_ repository: CatalogRepository) -> ScanCoordinator { ScanCoordinator(repository: repository) }

    private func entry(_ bytes: Data, path: String = "one.jpg") -> SourceEntry {
        SourceEntry(relativePath: path, metadata: SourceMetadata(revision: "r1", size: bytes.count))
    }









    func testTwoUnchangedScansAndReopenReuseOneInferenceResult() async throws {
        let h = try await ProducerHarness.make(self)
        let yuNet = ProducerYuNetBackend(), sFace = ProducerSFaceBackend()
        let persistent = h.persistent(ProducerFakeLoader(yuNet: yuNet, sFace: sFace))
        let first = EnrichmentSource(data: h.bytes, entries: [entry(h.bytes)])
        let result1 = await scanner(h.catalog).scan(source: first, detector: EnrichmentDetector(),
                                                   confirmedSource: true, enrichment: persistent) { _, _ in }
        XCTAssertEqual(result1.phase, .completed)
        let firstReadCount = await first.reads
        XCTAssertEqual(firstReadCount, 1)
        XCTAssertEqual(sFace.calls, 1, "one model inference for the first scan")
        let rows = try await h.catalog.faceVectorRows()
        XCTAssertEqual(rows.count, 1)

        // Second scan of the same trusted unchanged photo: zero reads, zero inference.
        let second = EnrichmentSource(data: h.bytes, entries: [entry(h.bytes)])
        let result2 = await scanner(h.catalog).scan(source: second, detector: EnrichmentDetector(),
                                                    confirmedSource: true, enrichment: persistent) { _, _ in }
        XCTAssertEqual(result2.phase, .completed)
        let secondReadCount = await second.reads
        XCTAssertEqual(secondReadCount, 0)
        XCTAssertEqual(sFace.calls, 1)

        // Relaunch: the reopened catalog reuses the durable analysis without reads or inference.
        let reopened = try h.reopen()
        let store = TransientFaceEmbeddingStore()
        let loader = ProducerFakeLoader(yuNet: ProducerYuNetBackend(), sFace: ProducerSFaceBackend())
        let producer = TransientFaceEmbeddingProducer(repository: reopened, store: store,
            token: store.begin(operationID: UUID(), sessionEpoch: 9), loader: loader)
        let relaunched = PersistentFaceAnalysisProducer(producer: producer, repository: reopened, store: store)
        let third = EnrichmentSource(data: h.bytes, entries: [entry(h.bytes)])
        let result3 = await scanner(reopened).scan(source: third, detector: EnrichmentDetector(),
                                                   confirmedSource: true, enrichment: relaunched) { _, _ in }
        XCTAssertEqual(result3.phase, .completed)
        let thirdReadCount = await third.reads
        XCTAssertEqual(thirdReadCount, 0)
        XCTAssertEqual(loader.sFace.calls, 0, "durable analysis is reused after relaunch")
        let reopenedRows = try await reopened.faceVectorRows()
        XCTAssertEqual(reopenedRows.count, 1)
        XCTAssertEqual(reopenedRows[0].faceKey, rows[0].faceKey)
    }

    func testNamingAfterPersistedScanCausesZeroReadsAndNoInference() async throws {
        let h = try await ProducerHarness.make(self)
        let yuNet = ProducerYuNetBackend(), sFace = ProducerSFaceBackend()
        let persistent = h.persistent(ProducerFakeLoader(yuNet: yuNet, sFace: sFace))
        _ = await scanner(h.catalog).scan(source: EnrichmentSource(data: h.bytes, entries: [entry(h.bytes)]),
                                          detector: EnrichmentDetector(), confirmedSource: true,
                                          enrichment: persistent) { _, _ in }
        XCTAssertEqual(sFace.calls, 1)
        let savedPhotos = try await h.catalog.photos()
        let photo = try XCTUnwrap(savedPhotos.first)
        let key = FaceKey(photo: photo, face: photo.analysis.faces[0])
        _ = try await h.catalog.applyDecision(.name(face: key, displayName: "Pat"))
        let named = try await h.catalog.peopleSnapshot().faces.first { $0.key == key }?.state
        XCTAssertNotNil(named?.personID)

        let second = EnrichmentSource(data: h.bytes, entries: [entry(h.bytes)])
        let result = await scanner(h.catalog).scan(source: second, detector: EnrichmentDetector(),
                                                  confirmedSource: true, enrichment: persistent) { _, _ in }
        XCTAssertEqual(result.phase, .completed)
        let secondReadCount = await second.reads
        XCTAssertEqual(secondReadCount, 0, "naming causes zero source reads")
        XCTAssertEqual(sFace.calls, 1, "naming causes zero inference")
        let state = try await h.catalog.peopleSnapshot().faces.first { $0.key == key }?.state
        XCTAssertEqual(state, named, "the human decision is untouched")
    }

    func testCatchUpPreservesExistingFaceKeysGeometryContentVersionAndManualIdentityWithoutDetectorCalls() async throws {
        let h = try await ProducerHarness.make(self)
        var photo = try await h.savePhoto(rects: [ProducerHarness.primaryRect])
        let key = FaceKey(photo: photo, face: photo.analysis.faces[0])
        _ = try await h.catalog.applyDecision(.name(face: key, displayName: "Pat"))
        let personID = try await h.catalog.peopleSnapshot().faces.first { $0.key == key }?.state.personID
        // A current preview makes the next scan take the trusted no-read path.
        let lease = try await h.catalog.acquireSource(identity: ProducerHarness.sourceIdentity, confirmed: true)
        let preview = try JPEGPreviewDecoder.jpeg(JPEGPreviewDecoder.decode(h.bytes))
        photo.previewPath = try await h.catalog.storePreview(preview, id: photo.id,
                                                             generation: "1-\(lease)", lease: lease)
        try await h.catalog.save(photo, progress: ScanProgress())
        let beforePhotos = try await h.catalog.photos()
        let before = try XCTUnwrap(beforePhotos.first { $0.id == photo.id })
        let beforeState = try await h.catalog.peopleSnapshot().faces.first { $0.key == key }?.state

        let detectorCalls = SFaceLockedCount()
        let yuNet = ProducerYuNetBackend(), sFace = ProducerSFaceBackend()
        let persistent = h.persistent(ProducerFakeLoader(yuNet: yuNet, sFace: sFace))
        let source = EnrichmentSource(data: h.bytes, entries: [entry(h.bytes, path: photo.relativePath)])
        let result = await scanner(h.catalog).scan(source: source, detector: CountingDetector(calls: detectorCalls),
                                                  confirmedSource: true, enrichment: persistent) { _, _ in }
        XCTAssertEqual(result.phase, .completed)
        XCTAssertEqual(detectorCalls.value, 0, "catch-up never reruns the catalog face detector")
        let sourceReadCount = await source.reads
        XCTAssertEqual(sourceReadCount, 1, "exactly one admitted catch-up read")
        XCTAssertEqual(sFace.calls, 1, "the missing analysis is computed once")

        let afterPhotos = try await h.catalog.photos()
        let after = try XCTUnwrap(afterPhotos.first { $0.id == photo.id })
        XCTAssertEqual(after.contentVersion, before.contentVersion)
        XCTAssertEqual(after.analysis, before.analysis, "stored Vision FaceKeys and geometry are preserved")
        XCTAssertEqual(after.contentHash, before.contentHash)
        let state = try await h.catalog.peopleSnapshot().faces.first { $0.key == key }?.state
        XCTAssertEqual(state, beforeState, "manual identity is untouched by catch-up")
        XCTAssertEqual(state?.personID, personID)
        let rows = try await h.catalog.faceVectorRows()
        XCTAssertEqual(rows.map(\.faceKey), [key])
        XCTAssertEqual(rows[0].contentVersion, before.contentVersion)
    }

    func testSuppressionDuringHeldInferencePreventsVectorInsertion() async throws {
        let h = try await ProducerHarness.make(self)
        let photo = try await h.savePhoto(rects: [ProducerHarness.primaryRect])
        let key = FaceKey(photo: photo, face: photo.analysis.faces[0])
        let gate = ProducerHoldGate(), yuNet = ProducerYuNetBackend(gate: gate), sFace = ProducerSFaceBackend()
        let persistent = h.persistent(ProducerFakeLoader(yuNet: yuNet, sFace: sFace))
        let run = Task { try await persistent.enrich(h.request(photo)) { _ in } }
        try await gate.waitEntered()
        try await h.catalog.suppressFace(key: key, photoID: photo.id, contentVersion: photo.contentVersion,
                                         contentHash: h.hash, sourceBinding: ProducerHarness.sourceIdentity)
        await gate.release()
        try await run.value
        let rows = try await h.catalog.faceVectorRows()
        XCTAssertTrue(rows.isEmpty, "suppression during in-flight inference prevents reinsertion")
        let suppressed = try await h.catalog.isFaceSuppressed(key: key)
        XCTAssertTrue(suppressed)
        let reused = try await h.catalog.satisfiesAnalysisReuse(photo: photo, manifest: manifest)
        XCTAssertTrue(reused, "a fully suppressed photo never reinfers")
        let admitted = try await h.catalog.needsAdmittedAnalysisRead(photo: photo, manifest: manifest)
        XCTAssertFalse(admitted)
    }

    func testChangedGenerationDuringHeldInferencePersistsNothing() async throws {
        let h = try await ProducerHarness.make(self)
        let photo = try await h.savePhoto(rects: [ProducerHarness.primaryRect])
        let gate = ProducerHoldGate(), yuNet = ProducerYuNetBackend(gate: gate), sFace = ProducerSFaceBackend()
        let persistent = h.persistent(ProducerFakeLoader(yuNet: yuNet, sFace: sFace))
        let run = Task { try await persistent.enrich(h.request(photo)) { _ in } }
        try await gate.waitEntered()
        let changed = PhotoIdentity(id: photo.id, relativePath: photo.relativePath, contentVersion: photo.contentVersion + 1,
                                    analysis: FaceAnalysisState(status: .successful, detectorVersion: photo.analysis.detectorVersion,
                                                                contentVersion: photo.contentVersion + 1, faces: photo.analysis.faces),
                                    contentHash: String(repeating: "b", count: 64))
        try await h.catalog.save(changed, progress: ScanProgress())
        await gate.release()
        await expectProducerError(.stale) { try await run.value }
        let rows = try await h.catalog.faceVectorRows()
        XCTAssertTrue(rows.isEmpty)
        let status = try await h.catalog.photoAnalysisStatus(photoID: photo.id, contentVersion: photo.contentVersion,
                                                             contentHash: h.hash, manifest: manifest)
        XCTAssertNil(status, "a changed generation cannot publish stale analysis")
    }

    func testCancelledEnrichmentPersistsNothing() async throws {
        let h = try await ProducerHarness.make(self)
        let photo = try await h.savePhoto(rects: [ProducerHarness.primaryRect])
        let gate = ProducerHoldGate(), trace = ProducerTrace()
        let yuNet = ProducerYuNetBackend(gate: gate, trace: trace), sFace = ProducerSFaceBackend(trace: trace)
        let persistent = h.persistent(ProducerFakeLoader(yuNet: yuNet, sFace: sFace))
        let run = Task { try await persistent.enrich(h.request(photo)) { _ in } }
        try await gate.waitEntered()
        run.cancel()
        await gate.release()
        do { try await run.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let rows = try await h.catalog.faceVectorRows()
        XCTAssertTrue(rows.isEmpty, "cancelled work cannot publish")
        let status = try await h.catalog.photoAnalysisStatus(photoID: photo.id, contentVersion: photo.contentVersion,
                                                             contentHash: h.hash, manifest: manifest)
        XCTAssertNil(status)
    }

    func testSourceRebindRefusesReuseAndPrunesStaleBindingRows() async throws {
        let h = try await ProducerHarness.make(self)
        let photo = try await h.savePhoto(rects: [ProducerHarness.primaryRect])
        let yuNet = ProducerYuNetBackend(), sFace = ProducerSFaceBackend()
        let persistent = h.persistent(ProducerFakeLoader(yuNet: yuNet, sFace: sFace))
        try await persistent.enrich(h.request(photo)) { _ in }
        XCTAssertEqual(sFace.calls, 1)
        var rows = try await h.catalog.faceVectorRows()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].sourceBinding, ProducerHarness.sourceIdentity)

        // Rebinding the catalog source refuses reuse of the old binding's analysis...
        _ = try await h.catalog.acquireSource(identity: "volume:other", confirmed: true)
        let rebound = try await h.catalog.satisfiesAnalysisReuse(photo: photo, manifest: manifest)
        XCTAssertFalse(rebound, "reuse must compare the actual current source binding")
        let admitted = try await h.catalog.needsAdmittedAnalysisRead(photo: photo, manifest: manifest)
        XCTAssertTrue(admitted, "a source-stale completed record deserves one admitted catch-up read")

        // ...and persisting under the new binding prunes the stale derived generation first.
        let reboundRequest = ScanEnrichmentRequest(photo: photo, entry: SourceEntry(relativePath: photo.relativePath),
            sourceIdentity: "volume:other", bytes: h.bytes, contentHash: h.hash)
        try await persistent.enrich(reboundRequest) { _ in }
        XCTAssertEqual(sFace.calls, 2)
        rows = try await h.catalog.faceVectorRows()
        XCTAssertEqual(rows.count, 1, "stale-binding rows are pruned before capacity admission")
        XCTAssertEqual(rows[0].sourceBinding, "volume:other")
    }

    func testStaleCallerGeometryRefusesReuse() async throws {
        let h = try await ProducerHarness.make(self)
        let photo = try await h.savePhoto(rects: [ProducerHarness.primaryRect])
        let persistent = h.persistent(ProducerFakeLoader(yuNet: ProducerYuNetBackend(), sFace: ProducerSFaceBackend()))
        try await persistent.enrich(h.request(photo)) { _ in }

        var staleCaller = photo
        staleCaller.analysis = FaceAnalysisState(status: .successful, detectorVersion: ProducerHarness.detectorVersion,
                                                 contentVersion: photo.contentVersion,
                                                 faces: [FaceGeometry(rectangle: [0.0, 0.85, 0.1, 0.1], landmarks: [])])
        let reused = try await h.catalog.satisfiesAnalysisReuse(photo: staleCaller, manifest: manifest)
        XCTAssertFalse(reused, "reuse must compare the actual current geometry, not the supplied identity")
        let currentReused = try await h.catalog.satisfiesAnalysisReuse(photo: photo, manifest: manifest)
        XCTAssertTrue(currentReused)
    }





    func testNamingAndDeletionDuringHeldInferenceRespectDurablePublication() async throws {
        for deleting in [false, true] {
            let h = try await ProducerHarness.make(self)
            let photo = try await h.savePhoto(rects: [ProducerHarness.primaryRect])
            let key = FaceKey(photo: photo, face: photo.analysis.faces[0])
            let hold = ProducerHoldGate()
            let persistent = h.persistent(ProducerFakeLoader(yuNet: ProducerYuNetBackend(gate: hold), sFace: ProducerSFaceBackend()))
            let run = Task { try await persistent.enrich(h.request(photo)) { _ in } }
            try await hold.waitEntered()
            _ = try await h.catalog.applyDecision(.name(face: key, displayName: "Fictional A"))
            let currentState = try await h.catalog.peopleSnapshot().faces.first { $0.key == key }?.state
            let state = try XCTUnwrap(currentState)
            if deleting {
                _ = try await h.catalog.deletePerson(try XCTUnwrap(state.personID),
                    group: FaceGroupSnapshot(seed: key, members: [key], expectedStates: [state]))
            }
            await hold.release()
            try await run.value
            let rows = try await h.catalog.faceVectorRows()
            XCTAssertEqual(rows.count, deleting ? 0 : 1)
            let after = try await h.catalog.peopleSnapshot().faces.first { $0.key == key }?.state
            XCTAssertEqual(after?.personID, deleting ? nil : state.personID)
        }
    }





    func testZeroFacePhotoRecordsEmptySuccessWithoutModelLoads() async throws {
        let h = try await ProducerHarness.make(self)
        let empty = try await h.savePhoto(rects: [], path: "empty.jpg")
        let loader = ProducerFakeLoader(yuNet: ProducerYuNetBackend(), sFace: ProducerSFaceBackend())
        let persistent = h.persistent(loader)
        try await persistent.enrich(h.request(empty)) { _ in }
        XCTAssertEqual(loader.loads.value, 0, "zero-face photos prepare no models")
        let status = try await h.catalog.photoAnalysisStatus(photoID: empty.id, contentVersion: empty.contentVersion,
                                                             contentHash: h.hash, manifest: manifest)
        XCTAssertEqual(status, .emptySuccess)
        let reused = try await h.catalog.satisfiesAnalysisReuse(photo: empty, manifest: manifest)
        XCTAssertTrue(reused)
        let admitted = try await h.catalog.needsAdmittedAnalysisRead(photo: empty, manifest: manifest)
        XCTAssertFalse(admitted)
        let rows = try await h.catalog.faceVectorRows()
        XCTAssertTrue(rows.isEmpty)
    }

    func testPipelineFailureRecordsExplicitFailureState() async throws {
        let h = try await ProducerHarness.make(self)
        let photo = try await h.savePhoto(rects: [ProducerHarness.primaryRect])
        let loader = FailingPipelineLoader()
        let producer = TransientFaceEmbeddingProducer(repository: h.catalog, store: h.store,
            token: h.store.begin(operationID: UUID(), sessionEpoch: 3), loader: loader)
        let persistent = PersistentFaceAnalysisProducer(producer: producer, repository: h.catalog, store: h.store)
        await expectProducerError(.pipelineFailed) { try await persistent.enrich(h.request(photo)) { _ in } }
        let status = try await h.catalog.photoAnalysisStatus(photoID: photo.id, contentVersion: photo.contentVersion,
                                                             contentHash: h.hash, manifest: manifest)
        XCTAssertEqual(status, .failed, "a failed pipeline is an explicit durable state")
        let rows = try await h.catalog.faceVectorRows()
        XCTAssertTrue(rows.isEmpty)
        let admitted = try await h.catalog.needsAdmittedAnalysisRead(photo: photo, manifest: manifest)
        XCTAssertFalse(admitted)
    }


}
