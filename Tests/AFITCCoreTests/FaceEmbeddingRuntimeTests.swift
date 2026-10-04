import AFITCCore
@testable import AFITCRuntime
import CryptoKit
import Foundation
import XCTest

final class FaceEmbeddingRuntimeTests: XCTestCase {
    func testWrongArtifactDigestIsRejectedBeforeBackendConstruction() async throws {
        let bytes = Data([1, 2, 3, 4, 5])
        let (url, directory) = try temporaryModel(bytes)
        defer { try? FileManager.default.removeItem(at: directory) }
        let factory = SFaceTestBackendFactory(backend: SFaceImmediateBackend(metadata: metadata(), output: vector()))
        let manifest = makeManifest(artifact: Data([5, 4, 3, 2, 1]))
        let recorder = SFaceProgressRecorder()

        do {
            _ = try await ModelPreparation(manifest: manifest, factory: factory).prepare(at: url) {
                recorder.append($0)
            }
            XCTFail("Wrong artifact bytes were accepted")
        } catch let error as FaceEmbeddingRuntimeError {
            XCTAssertEqual(error, .artifactRejected)
        }

        XCTAssertEqual(factory.constructionCount.value, 0)
        XCTAssertFalse(recorder.events.contains { $0.stage == .creatingSession })
        XCTAssertEqual(recorder.events.last?.stage, .failed)
    }

    func testPreparationReportsHashSessionAndReadyProgressAndRejectsMetadataDrift() async throws {
        let bytes = Data([11, 23, 37, 41])
        let (url, directory) = try temporaryModel(bytes)
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = SFaceImmediateBackend(metadata: metadata(), output: vector())
        let factory = SFaceTestBackendFactory(backend: backend)
        let recorder = SFaceProgressRecorder()
        let runtime = try await ModelPreparation(manifest: makeManifest(artifact: bytes), factory: factory)
            .prepare(at: url) { recorder.append($0) }

        let preparedManifest = await runtime.manifest
        XCTAssertEqual(preparedManifest.identifier, "test-sface")
        XCTAssertEqual(factory.constructionCount.value, 1)
        let events = recorder.events
        XCTAssertEqual(events.first?.stage, .verifyingArtifact)
        XCTAssertEqual(events.first?.completedUnits, 0)
        let hashProgress = events.filter { $0.stage == .verifyingArtifact }
        XCTAssertEqual(hashProgress.map(\.completedUnits), [0, Int64(bytes.count)])
        XCTAssertEqual(hashProgress.compactMap(\.totalUnits), [Int64(bytes.count), Int64(bytes.count)])
        XCTAssertEqual(events.map(\.stage), [.verifyingArtifact, .verifyingArtifact, .creatingSession, .ready])
        XCTAssertEqual(events.map(\.completedUnits), [0, Int64(bytes.count), 0, 1])

        let mismatches = [
            EmbeddingRuntimeMetadata(inputNames: ["unexpected"], inputShape: manifestInputShape,
                                     inputElementType: .float32, outputNames: ["fc1"],
                                     outputShape: [1, 128], outputElementType: .float32),
            EmbeddingRuntimeMetadata(inputNames: ["data"], inputShape: [1, 3, 112, 111],
                                     inputElementType: .float32, outputNames: ["fc1"],
                                     outputShape: [1, 128], outputElementType: .float32)
        ]
        for mismatch in mismatches {
            let badFactory = SFaceTestBackendFactory(backend: SFaceImmediateBackend(metadata: mismatch, output: vector()))
            let mismatchProgress = SFaceProgressRecorder()
            do {
                _ = try await ModelPreparation(manifest: makeManifest(artifact: bytes), factory: badFactory)
                    .prepare(at: url) { mismatchProgress.append($0) }
                XCTFail("Mismatched runtime metadata was accepted")
            } catch let error as FaceEmbeddingRuntimeError {
                XCTAssertEqual(error, .runtimeContractMismatch)
            }
            XCTAssertFalse(mismatchProgress.events.contains { $0.stage == .ready })
            XCTAssertEqual(mismatchProgress.events.last?.stage, .failed)
        }
    }

    func testPreparationCancellationDrainsHeldFactoryAndNeverReportsReady() async throws {
        let bytes = Data([13, 17, 19, 23])
        let (url, directory) = try temporaryModel(bytes)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = SFaceBlockingPreparationGate()
        let factory = SFaceHeldBackendFactory(backend: SFaceImmediateBackend(metadata: metadata(), output: vector()),
                                         gate: gate)
        let recorder = SFaceProgressRecorder()
        let returned = SFaceLockedFlag()
        let request = Task {
            defer { returned.set() }
            return try await ModelPreparation(manifest: makeManifest(artifact: bytes), factory: factory)
                .prepare(at: url) { recorder.append($0) }
        }
        try await gate.waitUntilEntered()
        request.cancel()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(returned.value, "Cancellation returned before the held factory drained")
        XCTAssertFalse(recorder.events.contains { $0.stage == .ready })

        gate.release()
        do {
            _ = try await request.value
            XCTFail("Cancelled preparation published a runtime")
        } catch is CancellationError {
        }
        XCTAssertTrue(gate.finished.value)
        XCTAssertTrue(returned.value)
        XCTAssertFalse(recorder.events.contains { $0.stage == .ready })
        XCTAssertEqual(recorder.events.last?.stage, .cancelled)
    }

    func testParentCancellationAfterPreparedChildCompletesNeverReportsReady() async throws {
        let bytes = Data([29, 31, 37, 41])
        let (url, directory) = try temporaryModel(bytes)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = SFaceBlockingPreparationGate()
        let backend = SFaceHeldMetadataBackend(metadata: metadata(), gate: gate, output: vector())
        let factory = SFaceTestBackendFactory(backend: backend)
        let recorder = SFaceProgressRecorder()
        let returned = SFaceLockedFlag()
        let request = Task {
            defer { returned.set() }
            return try await ModelPreparation(manifest: makeManifest(artifact: bytes), factory: factory)
                .prepare(at: url) { recorder.append($0) }
        }
        try await gate.waitUntilEntered()
        let constructionCount = factory.constructionCount.value
        XCTAssertEqual(constructionCount, 1, "Prepared child must return before parent reads metadata")
        request.cancel()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(returned.value, "Parent returned while metadata validation was held")
        gate.release()

        do {
            _ = try await request.value
            XCTFail("Cancelled parent published a prepared runtime")
        } catch is CancellationError {
        }
        XCTAssertTrue(returned.value)
        XCTAssertFalse(recorder.events.contains { $0.stage == .ready })
        XCTAssertEqual(recorder.events.last?.stage, .cancelled)
    }

    func testInvalidTensorAndStaleInputProvenanceNeverReachBackend() async throws {
        let backend = SFaceImmediateBackend(metadata: metadata(), output: vector())
        let runtime = FaceEmbeddingRuntime(manifest: makeManifest(artifact: Data([1])), backend: backend)

        do {
            _ = try await runtime.embedding(from: ModelTensor(shape: [1], values: [1]), provenance: provenance())
            XCTFail("Wrong tensor shape was accepted")
        } catch let error as FaceEmbeddingRuntimeError {
            XCTAssertEqual(error, .invalidInput)
        }
        do {
            _ = try await runtime.embedding(from: tensor(), provenance: provenance(preprocessingVersion: "other"))
            XCTFail("Wrong preprocessing provenance was accepted")
        } catch let error as FaceEmbeddingRuntimeError {
            XCTAssertEqual(error, .staleProvenance)
        }
        let calls = await backend.calls
        XCTAssertEqual(calls, 0)
    }

    func testSerialQueueRemainsSingleWorkerAcrossBackendSuspension() async throws {
        let backend = SFaceHeldBackend(metadata: metadata(), output: vector())
        let runtime = FaceEmbeddingRuntime(manifest: makeManifest(artifact: Data([1])), backend: backend)
        let firstProgress = SFaceProgressRecorder()
        let secondProgress = SFaceProgressRecorder()
        let first = Task {
            try await runtime.embedding(from: tensor(), provenance: provenance(),
                                        progress: { firstProgress.append($0) })
        }
        try await backend.waitForCalls(1)
        let second = Task {
            try await runtime.embedding(from: tensor(), provenance: provenance(),
                                        progress: { secondProgress.append($0) })
        }
        try await secondProgress.waitForStage(.queued)
        let callsBeforeRelease = await backend.callCount
        let concurrencyBeforeRelease = await backend.maximumConcurrency
        XCTAssertEqual(callsBeforeRelease, 1)
        XCTAssertEqual(concurrencyBeforeRelease, 1)

        await backend.releaseOne()
        _ = try await first.value
        try await backend.waitForCalls(2)
        let maximumConcurrency = await backend.maximumConcurrency
        XCTAssertEqual(maximumConcurrency, 1)
        await backend.releaseOne()
        _ = try await second.value
        XCTAssertEqual(firstProgress.events.map(\.stage), [.queued, .runningInference, .completed])
        XCTAssertEqual(secondProgress.events.map(\.stage), [.queued, .runningInference, .completed])
    }

    func testQueuedCancellationSkipsBackendAfterPriorWorkDrains() async throws {
        let backend = SFaceHeldBackend(metadata: metadata(), output: vector())
        let runtime = FaceEmbeddingRuntime(manifest: makeManifest(artifact: Data([1])), backend: backend)
        let first = Task { try await runtime.embedding(from: tensor(), provenance: provenance()) }
        try await backend.waitForCalls(1)
        let secondProgress = SFaceProgressRecorder()
        let second = Task {
            try await runtime.embedding(from: tensor(), provenance: provenance(),
                                        progress: { secondProgress.append($0) })
        }
        try await secondProgress.waitForStage(.queued)
        second.cancel()
        await backend.releaseOne()
        _ = try await first.value
        do {
            _ = try await second.value
            XCTFail("Cancelled queued work produced a result")
        } catch is CancellationError {
        }
        let calls = await backend.callCount
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(secondProgress.events.last?.stage, .cancelled)
    }

    func testQueuedStaleProvenanceNeverReachesBackendAfterPriorWorkDrains() async throws {
        let backend = SFaceHeldBackend(metadata: metadata(), output: vector())
        let runtime = FaceEmbeddingRuntime(manifest: makeManifest(artifact: Data([1])), backend: backend)
        let first = Task { try await runtime.embedding(from: tensor(), provenance: provenance()) }
        try await backend.waitForCalls(1)

        let current = SFaceLockedFlag(initialValue: true)
        let secondProgress = SFaceProgressRecorder()
        let second = Task {
            try await runtime.embedding(from: tensor(), provenance: provenance(),
                                        isCurrent: { _ in current.value },
                                        progress: { secondProgress.append($0) })
        }
        try await secondProgress.waitForStage(.queued)
        current.set(false)
        await backend.releaseOne()
        _ = try await first.value
        do {
            _ = try await second.value
            XCTFail("Stale queued work reached inference or produced a result")
        } catch let error as FaceEmbeddingRuntimeError {
            XCTAssertEqual(error, .staleProvenance)
        }
        let calls = await backend.callCount
        XCTAssertEqual(calls, 1, "Stale queued request must be rejected before the backend call")
        XCTAssertEqual(secondProgress.events.map(\.stage), [.queued, .failed])
    }

    func testActiveCancellationWaitsForBackendReturnAndSuppressesResult() async throws {
        let backend = SFaceHeldBackend(metadata: metadata(), output: vector())
        let runtime = FaceEmbeddingRuntime(manifest: makeManifest(artifact: Data([1])), backend: backend)
        let returned = SFaceLockedFlag()
        let request = Task {
            defer { returned.set() }
            return try await runtime.embedding(from: tensor(), provenance: provenance())
        }
        try await backend.waitForCalls(1)
        request.cancel()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(returned.value, "Cancellation returned before the backend call drained")

        await backend.releaseOne()
        do {
            _ = try await request.value
            XCTFail("Cancelled active work published a result")
        } catch is CancellationError {
        }
        XCTAssertTrue(returned.value)
        let calls = await backend.callCount
        XCTAssertEqual(calls, 1)
    }

    func testStaleProvenanceAfterInferenceDiscardsTheResult() async throws {
        let backend = SFaceHeldBackend(metadata: metadata(), output: vector())
        let runtime = FaceEmbeddingRuntime(manifest: makeManifest(artifact: Data([1])), backend: backend)
        let current = SFaceLockedFlag(initialValue: true)
        let request = Task {
            try await runtime.embedding(from: tensor(), provenance: provenance(),
                                        isCurrent: { _ in current.value })
        }
        try await backend.waitForCalls(1)
        current.set(false)
        await backend.releaseOne()
        do {
            _ = try await request.value
            XCTFail("Stale operation published an embedding")
        } catch let error as FaceEmbeddingRuntimeError {
            XCTAssertEqual(error, .staleProvenance)
        }
    }

    func testBackendFailureIsReportedWithoutAnEmbedding() async throws {
        let backend = SFaceImmediateBackend(metadata: metadata(), output: vector(), failure: true)
        let runtime = FaceEmbeddingRuntime(manifest: makeManifest(artifact: Data([1])), backend: backend)
        do {
            _ = try await runtime.embedding(from: tensor(), provenance: provenance())
            XCTFail("Backend failure produced an embedding")
        } catch let error as FaceEmbeddingRuntimeError {
            XCTAssertEqual(error, .backendFailed)
        }
    }

    func testParentReturnFenceRejectsCancellationAndStaleAfterCompletedCallback() async throws {
        for cancel in [true, false] {
            let backend = SFaceImmediateBackend(metadata: metadata(), output: vector())
            let runtime = FaceEmbeddingRuntime(manifest: makeManifest(artifact: Data([1])), backend: backend)
            let gate = SFaceCompletionBoundaryGate(), current = SFaceLockedFlag(initialValue: true)
            let returned = SFaceLockedFlag()
            let request = Task {
                defer { returned.set() }
                return try await runtime.embedding(from: tensor(), provenance: provenance(),
                    isCurrent: { _ in current.value }, progress: { if $0.stage == .completed { gate.hold() } })
            }
            try await gate.waitForEntry()
            let calls = await backend.calls; XCTAssertEqual(calls, 1)
            if cancel { request.cancel() } else { current.set(false) }
            try await Task.sleep(for: .milliseconds(20)); XCTAssertFalse(returned.value)
            gate.release()
            do { _ = try await request.value; XCTFail("Parent published after return-boundary invalidation") }
            catch is CancellationError { XCTAssertTrue(cancel) }
            catch let error as FaceEmbeddingRuntimeError { XCTAssertFalse(cancel); XCTAssertEqual(error, .staleProvenance) }
            XCTAssertTrue(returned.value)
        }
    }

    private var manifestInputShape: [Int] { [1, 3, 112, 112] }

    private func makeManifest(artifact: Data) -> ModelManifest {
        ModelManifest(identifier: "test-sface", sourceURL: "local-test", sourceRevision: "fixture",
                      licenseIdentifier: "test", artifactSHA256: Self.sha256(artifact),
                      artifactByteCount: artifact.count, inputName: "data", inputShape: manifestInputShape,
                      inputElementType: .float32, outputName: "fc1", outputShape: [1, 128],
                      outputElementType: .float32, preprocessingVersion: "sface-test-v1")
    }

    private func metadata() -> EmbeddingRuntimeMetadata {
        EmbeddingRuntimeMetadata(inputNames: ["data"], inputShape: manifestInputShape,
                                 inputElementType: .float32, outputNames: ["fc1"],
                                 outputShape: [1, 128], outputElementType: .float32)
    }

    private func tensor() throws -> ModelTensor {
        try ModelTensor(shape: manifestInputShape, values: [Float](repeating: 0.5, count: 3 * 112 * 112))
    }

    private func vector() -> EmbeddingVector {
        EmbeddingVector(modelIdentifier: "test-sface", values: [Float](repeating: 0.25, count: 128))
    }

    private func provenance(preprocessingVersion: String = "sface-test-v1") -> FaceEmbeddingProvenance {
        FaceEmbeddingProvenance(photoID: UUID(), contentVersion: 1, faceID: UUID(),
                                detectorVersion: "synthetic-v1", operationID: UUID(), sessionEpoch: 1,
                                modelIdentifier: "test-sface", preprocessingVersion: preprocessingVersion)
    }

    private func temporaryModel(_ data: Data) throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("model.onnx")
        try data.write(to: url)
        return (url, directory)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
