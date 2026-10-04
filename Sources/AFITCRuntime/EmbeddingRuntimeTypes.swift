import AFITCCore
import Foundation

/// Ephemeral identity carried across an embedding request and returned unchanged.
/// These values identify existing catalog/session rows; this type is not persisted.
public struct FaceEmbeddingProvenance: Equatable, Sendable {
    public let photoID: UUID
    public let contentVersion: Int
    public let faceID: UUID
    public let detectorVersion: String
    public let operationID: UUID
    public let sessionEpoch: UInt64
    public let modelIdentifier: String
    public let preprocessingVersion: String

    public init(photoID: UUID, contentVersion: Int, faceID: UUID, detectorVersion: String,
                operationID: UUID, sessionEpoch: UInt64, modelIdentifier: String,
                preprocessingVersion: String) {
        self.photoID = photoID
        self.contentVersion = contentVersion
        self.faceID = faceID
        self.detectorVersion = detectorVersion
        self.operationID = operationID
        self.sessionEpoch = sessionEpoch
        self.modelIdentifier = modelIdentifier
        self.preprocessingVersion = preprocessingVersion
    }
}

/// Progress is reported only for work that has actually started or completed.
public struct FaceEmbeddingProgress: Equatable, Sendable {
    public enum Stage: String, Sendable {
        case verifyingArtifact
        case creatingSession
        case ready
        case queued
        case runningInference
        case completed
        case cancelled
        case failed
    }

    public let stage: Stage
    public let completedUnits: Int64
    public let totalUnits: Int64?
    public let modelIdentifier: String

    public init(stage: Stage, completedUnits: Int64, totalUnits: Int64?, modelIdentifier: String) {
        self.stage = stage
        self.completedUnits = completedUnits
        self.totalUnits = totalUnits
        self.modelIdentifier = modelIdentifier
    }
}

/// A successful inference paired with the exact request generation that produced it.
public struct FaceEmbeddingResult: Equatable, Sendable {
    public let provenance: FaceEmbeddingProvenance
    public let embedding: EmbeddingVector

    public init(provenance: FaceEmbeddingProvenance, embedding: EmbeddingVector) {
        self.provenance = provenance
        self.embedding = embedding
    }
}

/// Fail-closed outcomes exposed by model preparation and inference.
public enum FaceEmbeddingRuntimeError: Error, Equatable, Sendable {
    case modelUnavailable
    case artifactRejected
    case sessionCreationFailed
    case runtimeContractMismatch
    case invalidInput
    case staleProvenance
    case backendFailed
}

struct EmbeddingRuntimeMetadata: Equatable, Sendable {
    let inputNames: [String]
    let inputShape: [Int]
    let inputElementType: ModelElementType
    let outputNames: [String]
    let outputShape: [Int]
    let outputElementType: ModelElementType
}

struct VerifiedModelArtifact: Sendable {
    let url: URL
    let byteCount: Int
    let sha256: String
}

protocol EmbeddingInferenceBackend: Sendable {
    var metadata: EmbeddingRuntimeMetadata { get }
    func infer(_ input: ModelTensor) async throws -> EmbeddingVector
}

protocol EmbeddingInferenceBackendFactory: Sendable {
    func makeBackend(artifact: VerifiedModelArtifact, manifest: ModelManifest) throws
        -> any EmbeddingInferenceBackend
}

public typealias FaceEmbeddingProgressHandler = @Sendable (FaceEmbeddingProgress) -> Void
