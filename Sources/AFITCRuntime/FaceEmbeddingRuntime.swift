import AFITCCore
import Foundation

/// A single-worker inference queue with cancellation and source-generation fencing.
public actor FaceEmbeddingRuntime {
    public let manifest: ModelManifest
    private let backend: any EmbeddingInferenceBackend
    private var queueTail: Task<Void, Never>?

    init(manifest: ModelManifest, backend: any EmbeddingInferenceBackend) {
        self.manifest = manifest
        self.backend = backend
    }

    /// Runs one tensor and returns only if cancellation and provenance fences still pass.
    public func embedding(
        from input: ModelTensor,
        provenance: FaceEmbeddingProvenance,
        isCurrent: @escaping @Sendable (FaceEmbeddingProvenance) -> Bool = { _ in true },
        progress: @escaping FaceEmbeddingProgressHandler = { _ in }
    ) async throws -> FaceEmbeddingResult {
        guard !Task.isCancelled else { throw CancellationError() }
        guard provenance.modelIdentifier == manifest.identifier,
              provenance.preprocessingVersion == manifest.preprocessingVersion,
              isCurrent(provenance) else {
            throw FaceEmbeddingRuntimeError.staleProvenance
        }
        guard input.shape == manifest.inputShape,
              input.values.count == manifest.inputShape.reduce(1, *),
              input.values.allSatisfy(\.isFinite) else {
            throw FaceEmbeddingRuntimeError.invalidInput
        }

        let cancellation = InferenceCancellationGate()
        let previous = queueTail
        let backend = self.backend
        let manifest = self.manifest
        progress(FaceEmbeddingProgress(stage: .queued, completedUnits: 0,
                                       totalUnits: 1, modelIdentifier: manifest.identifier))
        let work = Task.detached(priority: .userInitiated) {
            await previous?.value
            guard cancellation.beginIfNotCancelled() else {
                progress(FaceEmbeddingProgress(stage: .cancelled, completedUnits: 0,
                                               totalUnits: 1, modelIdentifier: manifest.identifier))
                throw CancellationError()
            }
            guard isCurrent(provenance) else {
                progress(FaceEmbeddingProgress(stage: .failed, completedUnits: 0,
                                               totalUnits: 1, modelIdentifier: manifest.identifier))
                throw FaceEmbeddingRuntimeError.staleProvenance
            }
            progress(FaceEmbeddingProgress(stage: .runningInference, completedUnits: 0,
                                           totalUnits: 1, modelIdentifier: manifest.identifier))
            let embedding: EmbeddingVector
            do {
                embedding = try await backend.infer(input)
            } catch {
                if cancellation.isCancelled {
                    progress(FaceEmbeddingProgress(stage: .cancelled, completedUnits: 0,
                                                   totalUnits: 1, modelIdentifier: manifest.identifier))
                    throw CancellationError()
                }
                progress(FaceEmbeddingProgress(stage: .failed, completedUnits: 0,
                                               totalUnits: 1, modelIdentifier: manifest.identifier))
                throw error
            }
            guard !cancellation.isCancelled else {
                progress(FaceEmbeddingProgress(stage: .cancelled, completedUnits: 0,
                                               totalUnits: 1, modelIdentifier: manifest.identifier))
                throw CancellationError()
            }
            guard isCurrent(provenance) else {
                progress(FaceEmbeddingProgress(stage: .failed, completedUnits: 0,
                                               totalUnits: 1, modelIdentifier: manifest.identifier))
                throw FaceEmbeddingRuntimeError.staleProvenance
            }
            guard embedding.modelIdentifier == manifest.identifier,
                  embedding.values.count == manifest.outputShape.last,
                  embedding.values.allSatisfy(\.isFinite) else {
                progress(FaceEmbeddingProgress(stage: .failed, completedUnits: 0,
                                               totalUnits: 1, modelIdentifier: manifest.identifier))
                throw FaceEmbeddingRuntimeError.runtimeContractMismatch
            }
            progress(FaceEmbeddingProgress(stage: .completed, completedUnits: 1,
                                           totalUnits: 1, modelIdentifier: manifest.identifier))
            return FaceEmbeddingResult(provenance: provenance, embedding: embedding)
        }
        queueTail = Task.detached(priority: nil) { _ = try? await work.value }
        return try await withTaskCancellationHandler {
            let result = try await work.value
            // The completed callback can outlive the child's final fence. Recheck in the parent.
            try Task.checkCancellation()
            guard isCurrent(provenance) else { throw FaceEmbeddingRuntimeError.staleProvenance }
            return result
        } onCancel: {
            cancellation.cancel()
        }
    }
}

private final class InferenceCancellationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var started = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func beginIfNotCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled, !started else { return false }
        started = true
        return true
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}
