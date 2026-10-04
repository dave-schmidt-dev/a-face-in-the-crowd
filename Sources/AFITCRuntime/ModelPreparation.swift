import AFITCCore
import CryptoKit
import Foundation

/// Verifies the pinned artifact before constructing an inference session.
public struct ModelPreparation: Sendable {
    public let manifest: ModelManifest
    private let factory: any EmbeddingInferenceBackendFactory

    public init(manifest: ModelManifest = .openCVSFace2021December) {
        self.manifest = manifest
        self.factory = SFaceCPUBackendFactory()
    }

    init(manifest: ModelManifest, factory: any EmbeddingInferenceBackendFactory) {
        self.manifest = manifest
        self.factory = factory
    }

    /// Hashes the file, validates its manifest, creates the CPU session, then checks its contract.
    public func prepare(
        at modelURL: URL,
        progress: @escaping FaceEmbeddingProgressHandler = { _ in }
    ) async throws -> FaceEmbeddingRuntime {
        let modelIdentifier = manifest.identifier
        let factory = self.factory
        let preparation = Task.detached(priority: .userInitiated) {
            let artifact = try Self.verifyArtifact(at: modelURL, manifest: self.manifest,
                                                   progress: progress)
            try Task.checkCancellation()
            progress(FaceEmbeddingProgress(stage: .creatingSession, completedUnits: 0,
                                           totalUnits: 1, modelIdentifier: modelIdentifier))
            do {
                let backend = try factory.makeBackend(artifact: artifact, manifest: self.manifest)
                try Task.checkCancellation()
                return backend
            } catch let error as FaceEmbeddingRuntimeError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw FaceEmbeddingRuntimeError.sessionCreationFailed
            }
        }
        do {
            let backend = try await withTaskCancellationHandler {
                try await preparation.value
            } onCancel: {
                preparation.cancel()
            }
            try Task.checkCancellation()

            let metadata = backend.metadata
            do {
                try manifest.validateRuntime(inputNames: metadata.inputNames,
                                             inputShape: metadata.inputShape,
                                             inputType: metadata.inputElementType,
                                             outputNames: metadata.outputNames,
                                             outputShape: metadata.outputShape,
                                             outputType: metadata.outputElementType)
            } catch {
                throw FaceEmbeddingRuntimeError.runtimeContractMismatch
            }
            try Task.checkCancellation()
            progress(FaceEmbeddingProgress(stage: .ready, completedUnits: 1,
                                           totalUnits: 1, modelIdentifier: modelIdentifier))
            return FaceEmbeddingRuntime(manifest: manifest, backend: backend)
        } catch let error as FaceEmbeddingRuntimeError {
            progress(FaceEmbeddingProgress(stage: .failed, completedUnits: 0,
                                           totalUnits: nil, modelIdentifier: modelIdentifier))
            throw error
        } catch is CancellationError {
            progress(FaceEmbeddingProgress(stage: .cancelled, completedUnits: 0,
                                           totalUnits: nil, modelIdentifier: modelIdentifier))
            throw CancellationError()
        } catch {
            progress(FaceEmbeddingProgress(stage: .failed, completedUnits: 0,
                                           totalUnits: nil, modelIdentifier: modelIdentifier))
            throw FaceEmbeddingRuntimeError.modelUnavailable
        }
    }

    private static func verifyArtifact(
        at url: URL,
        manifest: ModelManifest,
        progress: FaceEmbeddingProgressHandler
    ) throws -> VerifiedModelArtifact {
        try Task.checkCancellation()
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw FaceEmbeddingRuntimeError.modelUnavailable
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let byteCount = (attributes[.size] as? NSNumber)?.intValue,
              byteCount > 0 else {
            throw FaceEmbeddingRuntimeError.modelUnavailable
        }

        progress(FaceEmbeddingProgress(stage: .verifyingArtifact, completedUnits: 0,
                                      totalUnits: Int64(byteCount), modelIdentifier: manifest.identifier))
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            var completed: Int64 = 0
            while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: data)
                completed += Int64(data.count)
                progress(FaceEmbeddingProgress(stage: .verifyingArtifact, completedUnits: completed,
                                               totalUnits: Int64(byteCount), modelIdentifier: manifest.identifier))
            }
            guard completed == byteCount else { throw FaceEmbeddingRuntimeError.artifactRejected }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            do {
                try manifest.validateArtifact(byteCount: byteCount, sha256: digest)
            } catch {
                throw FaceEmbeddingRuntimeError.artifactRejected
            }
            try Task.checkCancellation()
            return VerifiedModelArtifact(url: url, byteCount: byteCount, sha256: digest)
        } catch let error as FaceEmbeddingRuntimeError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw FaceEmbeddingRuntimeError.modelUnavailable
        }
    }
}
