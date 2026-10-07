import AFITCCore
@testable import AFITCRuntime
import Foundation
import XCTest

struct SFaceTestBackendFactory: EmbeddingInferenceBackendFactory {
    let backend: any EmbeddingInferenceBackend
    let constructionCount = SFaceLockedCount()

    func makeBackend(artifact: VerifiedModelArtifact, manifest: ModelManifest) throws
        -> any EmbeddingInferenceBackend {
        constructionCount.increment()
        return backend
    }
}

struct SFaceHeldBackendFactory: EmbeddingInferenceBackendFactory {
    let backend: any EmbeddingInferenceBackend
    let gate: SFaceBlockingPreparationGate

    func makeBackend(artifact: VerifiedModelArtifact, manifest: ModelManifest) throws
        -> any EmbeddingInferenceBackend {
        gate.waitUntilReleased()
        return backend
    }
}

actor SFaceImmediateBackend: EmbeddingInferenceBackend {
    let metadata: EmbeddingRuntimeMetadata
    private let output: EmbeddingVector
    private let failure: Bool
    private(set) var calls = 0

    init(metadata: EmbeddingRuntimeMetadata, output: EmbeddingVector, failure: Bool = false) {
        self.metadata = metadata
        self.output = output
        self.failure = failure
    }

    func infer(_ input: ModelTensor) async throws -> EmbeddingVector {
        calls += 1
        if failure { throw FaceEmbeddingRuntimeError.backendFailed }
        return output
    }
}

actor SFaceHeldBackend: EmbeddingInferenceBackend {
    let metadata: EmbeddingRuntimeMetadata
    private let output: EmbeddingVector
    private var active = 0
    private(set) var maximumConcurrency = 0
    private(set) var callCount = 0
    private var waiters: [CheckedContinuation<EmbeddingVector, Never>] = []

    init(metadata: EmbeddingRuntimeMetadata, output: EmbeddingVector) {
        self.metadata = metadata
        self.output = output
    }

    func infer(_ input: ModelTensor) async throws -> EmbeddingVector {
        active += 1
        callCount += 1
        maximumConcurrency = max(maximumConcurrency, active)
        let value = await withCheckedContinuation { waiters.append($0) }
        active -= 1
        return value
    }

    func waitForCalls(_ expected: Int) async throws {
        for _ in 0..<2_000 {
            if callCount >= expected { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Backend did not receive the expected request")
    }

    func releaseOne() {
        guard !waiters.isEmpty else { XCTFail("No held backend request to release"); return }
        waiters.removeFirst().resume(returning: output)
    }
}

final class SFaceHeldMetadataBackend: EmbeddingInferenceBackend, @unchecked Sendable {
    private let storedMetadata: EmbeddingRuntimeMetadata
    private let gate: SFaceBlockingPreparationGate
    private let output: EmbeddingVector

    init(metadata: EmbeddingRuntimeMetadata, gate: SFaceBlockingPreparationGate, output: EmbeddingVector) {
        storedMetadata = metadata
        self.gate = gate
        self.output = output
    }

    var metadata: EmbeddingRuntimeMetadata {
        gate.waitUntilReleased()
        return storedMetadata
    }

    func infer(_ input: ModelTensor) async throws -> EmbeddingVector { output }
}

final class SFaceBlockingPreparationGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let enteredFlag = SFaceLockedFlag()
    let finished = SFaceLockedFlag()

    func waitUntilReleased() {
        enteredFlag.set()
        semaphore.wait()
        finished.set()
    }

    func release() { semaphore.signal() }

    func waitUntilEntered() async throws {
        for _ in 0..<2_000 {
            if enteredFlag.value { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Preparation gate was not entered")
    }
}

final class SFaceLockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

final class SFaceLockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool
    init(initialValue: Bool = false) { stored = initialValue }
    var value: Bool { lock.withLock { stored } }
    func set(_ value: Bool = true) { lock.withLock { stored = value } }
}

final class SFaceProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [FaceEmbeddingProgress] = []
    var events: [FaceEmbeddingProgress] { lock.withLock { stored } }
    func append(_ event: FaceEmbeddingProgress) { lock.withLock { stored.append(event) } }

    func waitForStage(_ stage: FaceEmbeddingProgress.Stage) async throws {
        for _ in 0..<2_000 {
            if events.contains(where: { $0.stage == stage }) { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Progress stage \(stage.rawValue) was not emitted")
    }
}

/// Holds the real completed progress callback after actual backend return.
final class SFaceCompletionBoundaryGate: @unchecked Sendable {
    private let entered = SFaceLockedFlag()
    private let semaphore = DispatchSemaphore(value: 0)
    func hold() { entered.set(); if semaphore.wait(timeout: .now() + 60) != .success { XCTFail("Completion callback timeout") } }
    func release() { semaphore.signal() }
    func waitForEntry() async throws {
        let deadline = ContinuousClock.now + .seconds(60)
        while !entered.value {
            guard ContinuousClock.now < deadline else { throw FaceEmbeddingRuntimeError.backendFailed }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
