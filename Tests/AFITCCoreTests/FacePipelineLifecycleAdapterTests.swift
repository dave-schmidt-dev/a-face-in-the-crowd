@testable import AFITCCore
@testable import AFITCRuntime
import Foundation
import XCTest

/// Lifecycle of the production store/producer adapter that the App facade wraps.
final class FacePipelineLifecycleAdapterTests: XCTestCase {
    func testMainActorClearDuringHeldFinalInferenceSynchronouslyDropsAndPreventsLatePublish() async throws {
        let h = try await ProducerHarness.make(self)
        let photo = try await h.savePhoto(rects: [ProducerHarness.primaryRect])
        let first = h.producer(ProducerFakeLoader(yuNet: ProducerYuNetBackend(), sFace: ProducerSFaceBackend()))
        try await first.enrich(h.request(photo)) { _ in }
        XCTAssertNotNil(h.store.latestBatch)

        let gate = ProducerHoldGate(), trace = ProducerTrace()
        let sFace = ProducerSFaceBackend(gate: gate, trace: trace)
        let producer = h.producer(ProducerFakeLoader(yuNet: ProducerYuNetBackend(), sFace: sFace))
        XCTAssertNil(h.store.latestBatch, "a new operation token drops the previous batch")
        await expectProducerError(.stale) { try await first.enrich(h.request(photo)) { _ in } }

        let messages = ProducerMessages()
        let run = Task { try await producer.enrich(h.request(photo)) { messages.append($0) } }
        try await gate.waitEntered()
        let cleared = await MainActor.run { () -> Bool in
            h.store.invalidate()
            return h.store.latestBatch == nil
        }
        XCTAssertTrue(cleared, "clear is synchronous on the MainActor")
        let countAtClear = messages.values.count
        await gate.release()
        await expectProducerError(.stale) { try await run.value }
        XCTAssertEqual(trace.events, ["sface-entered", "sface-returned"], "actual runtime drained before stale")
        XCTAssertNil(h.store.latestBatch, "late completion cannot publish after clear")
        XCTAssertEqual(messages.values.count, countAtClear, "no progress after clear")
    }

    func testLatestSinglePhotoBatchReplacesPreviousAndIsNotEncodable() async throws {
        let h = try await ProducerHarness.make(self)
        let one = try await h.savePhoto(rects: [ProducerHarness.primaryRect], path: "one.jpg")
        let two = try await h.savePhoto(rects: [ProducerHarness.primaryRect], path: "two.jpg")
        let producer = h.producer(ProducerFakeLoader(yuNet: ProducerYuNetBackend(), sFace: ProducerSFaceBackend()))
        try await producer.enrich(h.request(one)) { _ in }
        XCTAssertEqual(h.store.latestBatch?.photoID, one.id)
        try await producer.enrich(h.request(two)) { _ in }
        let batch = try XCTUnwrap(h.store.latestBatch)
        XCTAssertEqual(batch.photoID, two.id)
        XCTAssertEqual(batch.rows.map(\.visionFaceID), two.analysis.faces.map(\.id))
        XCTAssertFalse((batch as Any) is any Encodable)
        XCTAssertFalse((batch as Any) is any Decodable)
    }

    func testSyntheticFixtureBypassesTrainedModelsAndProductionPathIssuesCurrentToken() async throws {
        let h = try await ProducerHarness.make(self)
        let photo = try await h.savePhoto(rects: [ProducerHarness.primaryRect])
        try await h.producer(ProducerFakeLoader(yuNet: ProducerYuNetBackend(), sFace: ProducerSFaceBackend()))
            .enrich(h.request(photo)) { _ in }
        XCTAssertNotNil(h.store.latestBatch)
        XCTAssertNil(h.store.makeEnrichment(repository: h.catalog, operationID: UUID(), sessionEpoch: 1,
                                            syntheticFixture: true))
        XCTAssertNil(h.store.latestBatch, "synthetic scans also drop any previous batch")
        let production = h.store.makeEnrichment(repository: h.catalog, operationID: UUID(), sessionEpoch: 2,
                                                syntheticFixture: false)
        XCTAssertNotNil(production)
        let prepared = await production?.hasPreparedModels
        XCTAssertEqual(prepared, false, "bundled models are prepared lazily, never at construction")
    }

    func testPreparationFailureIsRetainedForTheScanAndReportedUnavailable() async throws {
        let h = try await ProducerHarness.make(self)
        let one = try await h.savePhoto(rects: [ProducerHarness.primaryRect], path: "one.jpg")
        let two = try await h.savePhoto(rects: [ProducerHarness.primaryRect], path: "two.jpg")
        var loader = ProducerFakeLoader(yuNet: ProducerYuNetBackend(), sFace: ProducerSFaceBackend())
        loader.fails = true
        let producer = h.producer(loader)
        await expectProducerError(.modelsUnavailable) { try await producer.enrich(h.request(one)) { _ in } }
        let messages = ProducerMessages()
        await expectProducerError(.modelsUnavailable) { try await producer.enrich(h.request(two)) { messages.append($0) } }
        XCTAssertEqual(loader.loads.value, 1, "failed preparation is not repeated per photo")
        XCTAssertTrue(messages.values.isEmpty, "no preparing message once preparation is known unavailable")
        XCTAssertNil(h.store.latestBatch)
    }

    func testReleaseAfterDrainDropsModelHandlesAndRejectsLaterRequests() async throws {
        let h = try await ProducerHarness.make(self)
        let photo = try await h.savePhoto(rects: [ProducerHarness.primaryRect])
        let yuNet = ProducerYuNetBackend()
        let loader = ProducerFakeLoader(yuNet: yuNet, sFace: ProducerSFaceBackend())
        let producer = h.producer(loader)
        try await producer.enrich(h.request(photo)) { _ in }
        var prepared = await producer.hasPreparedModels
        XCTAssertTrue(prepared)
        await producer.release()
        prepared = await producer.hasPreparedModels
        XCTAssertFalse(prepared)
        await expectProducerError(.stale) { try await producer.enrich(h.request(photo)) { _ in } }
        XCTAssertEqual(loader.loads.value, 1); XCTAssertEqual(yuNet.calls, 1)
        XCTAssertNotNil(h.store.latestBatch, "release drops model handles, not the current published result")
    }

    func testCancellationDuringHeldYuNetDrainsAndPublishesNothing() async throws {
        let h = try await ProducerHarness.make(self)
        let photo = try await h.savePhoto(rects: [ProducerHarness.primaryRect])
        let gate = ProducerHoldGate(), trace = ProducerTrace()
        let producer = h.producer(ProducerFakeLoader(yuNet: ProducerYuNetBackend(gate: gate, trace: trace),
                                                     sFace: ProducerSFaceBackend(trace: trace)))
        let finished = SFaceLockedFlag()
        let run = Task { defer { finished.set() }; try await producer.enrich(h.request(photo)) { _ in } }
        try await gate.waitEntered()
        run.cancel()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(finished.value, "cancellation waits for the actual backend return")
        await gate.release()
        do { try await run.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(trace.events, ["yunet-entered", "yunet-returned"])
        XCTAssertNil(h.store.latestBatch)
    }
}
