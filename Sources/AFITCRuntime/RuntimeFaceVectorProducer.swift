import AFITCCore
import Foundation

/// Adapts the existing per-scan transient producer to `FaceVectorProducing`. It runs the unchanged
/// producer, then reads the store's single retained batch only when that batch belongs to exactly
/// this request's photo, content version, verified hash and SFace manifest.
public struct RuntimeFaceVectorProducer: FaceVectorProducing {
    private let producer: TransientFaceEmbeddingProducer
    private let store: TransientFaceEmbeddingStore
    public let manifest: ModelManifest

    /// Wraps one scan's producer and the store it publishes to.
    public init(producer: TransientFaceEmbeddingProducer, store: TransientFaceEmbeddingStore,
                manifest: ModelManifest = .openCVSFace2021December) {
        self.producer = producer; self.store = store; self.manifest = manifest
    }

    /// Runs the wrapped producer, then maps matching embedded rows to vectors keyed by face ID.
    /// Producer staleness or a batch for any other photo, version, hash or model is `.stale`.
    public func produce(_ request: ScanEnrichmentRequest,
                        progress: @escaping ScanEnrichmentProgress) async throws -> FaceVectorProduction {
        do { try await producer.enrich(request, progress: progress) }
        catch TransientFaceEmbeddingError.stale { throw FaceVectorProductionError.stale }
        guard let batch = store.latestBatch, batch.photoID == request.photo.id,
              batch.contentVersion == request.photo.contentVersion, batch.fence.contentHash == request.contentHash,
              batch.sFaceModelIdentifier == manifest.identifier else { throw FaceVectorProductionError.stale }
        var vectors: [UUID: EmbeddingVector] = [:]
        for row in batch.rows {
            guard case .embedded(let result, _) = row.outcome else { continue }
            let provenance = result.provenance
            guard provenance.faceID == row.visionFaceID, provenance.photoID == batch.photoID,
                  provenance.contentVersion == batch.contentVersion,
                  provenance.modelIdentifier == manifest.identifier,
                  provenance.preprocessingVersion == manifest.preprocessingVersion,
                  result.embedding.modelIdentifier == manifest.identifier else { continue }
            vectors[row.visionFaceID] = result.embedding
        }
        return FaceVectorProduction(photoID: batch.photoID, contentVersion: batch.contentVersion,
                                    contentHash: request.contentHash, vectors: vectors)
    }

    /// Drops the wrapped producer's model handles after the owning scan has returned.
    public func release() async { await producer.release() }
}
