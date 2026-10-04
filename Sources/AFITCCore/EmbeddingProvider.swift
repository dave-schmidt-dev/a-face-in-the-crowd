import Foundation

/// A contiguous, finite float tensor passed across the model-provider boundary.
public struct ModelTensor: Equatable, Sendable {
    public let shape: [Int]
    public let values: [Float]

    public init(shape: [Int], values: [Float]) throws {
        guard !shape.isEmpty, shape.allSatisfy({ $0 > 0 }) else { throw EmbeddingContractError.invalidShape }
        var count = 1
        for dimension in shape {
            let (product, overflow) = count.multipliedReportingOverflow(by: dimension)
            guard !overflow else { throw EmbeddingContractError.invalidShape }
            count = product
        }
        guard values.count == count else { throw EmbeddingContractError.valueCountMismatch }
        guard values.allSatisfy(\.isFinite) else { throw EmbeddingContractError.nonFiniteValues }
        self.shape = shape
        self.values = values
    }
}

/// A model feature vector tagged with the model identity that produced it.
public struct EmbeddingVector: Equatable, Sendable {
    public let modelIdentifier: String
    public let values: [Float]

    public init(modelIdentifier: String, values: [Float]) {
        self.modelIdentifier = modelIdentifier
        self.values = values
    }

    /// Returns a validated unit-length vector for the expected model and dimension.
    public func normalized(using manifest: ModelManifest) throws -> EmbeddingVector {
        guard modelIdentifier == manifest.identifier else { throw EmbeddingContractError.modelMismatch }
        guard values.count == manifest.outputShape.last else { throw EmbeddingContractError.dimensionMismatch }
        guard values.allSatisfy(\.isFinite) else { throw EmbeddingContractError.nonFiniteValues }
        let squaredNorm = values.reduce(0.0) { $0 + Double($1) * Double($1) }
        guard squaredNorm.isFinite, squaredNorm > 0 else { throw EmbeddingContractError.zeroNorm }
        let norm = sqrt(squaredNorm)
        let normalized = values.map { Float(Double($0) / norm) }
        guard normalized.allSatisfy(\.isFinite) else { throw EmbeddingContractError.nonFiniteValues }
        return EmbeddingVector(modelIdentifier: modelIdentifier, values: normalized)
    }

    /// Computes cosine similarity after validating model identity and vector dimensions.
    public func cosineSimilarity(to other: EmbeddingVector, using manifest: ModelManifest) throws -> Double {
        let lhs = try normalized(using: manifest).values
        let rhs = try other.normalized(using: manifest).values
        guard lhs.count == rhs.count else { throw EmbeddingContractError.dimensionMismatch }
        let score = zip(lhs, rhs).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
        guard score.isFinite else { throw EmbeddingContractError.nonFiniteValues }
        return min(1.0, max(-1.0, score))
    }
}

/// Provider-independent errors shared by model adapters and tests.
public enum EmbeddingContractError: Error, Equatable, Sendable {
    case invalidShape
    case valueCountMismatch
    case nonFiniteValues
    case modelMismatch
    case dimensionMismatch
    case zeroNorm
}

/// A local inference adapter that produces vectors for a validated model manifest.
public protocol EmbeddingProvider: Sendable {
    var manifest: ModelManifest { get }

    /// Runs inference on a tensor prepared according to `manifest`.
    func embedding(from input: ModelTensor) async throws -> EmbeddingVector
}
