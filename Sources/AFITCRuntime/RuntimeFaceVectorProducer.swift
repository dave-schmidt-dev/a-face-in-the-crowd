import AFITCCore
import Foundation

/// Adapts a scan enrichment (the durable persistent producer, or the bare transient producer)
/// to `FaceVectorProducing`. It runs the wrapped enrichment, then reads the store's single
/// retained batch only when that batch belongs to exactly this request's photo, content
/// version, verified hash and SFace manifest.
public struct RuntimeFaceVectorProducer: FaceVectorProducing {
    private let enrichment: any ScanEnrichment
    private let store: TransientFaceEmbeddingStore
    public let manifest: ModelManifest

    /// Wraps one scan's enrichment and the store its pinned producer publishes to.
    public init(enrichment: any ScanEnrichment, store: TransientFaceEmbeddingStore,
                manifest: ModelManifest = .openCVSFace2021December) {
        self.enrichment = enrichment; self.store = store; self.manifest = manifest
    }

    /// Runs the wrapped enrichment, then maps matching embedded rows to vectors keyed by face ID.
    /// Producer staleness or a batch for any other photo, version, hash or model is `.stale`.
    public func produce(_ request: ScanEnrichmentRequest,
                        progress: @escaping ScanEnrichmentProgress) async throws -> FaceVectorProduction {
        do { try await enrichment.enrich(request, progress: progress) }
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

    /// Forwards the catch-up admission question to the wrapped enrichment.
    public func needsAdmittedRead(_ photo: PhotoIdentity) async -> Bool {
        await enrichment.needsAdmittedRead(photo)
    }

    /// Drops the wrapped producer's model handles after the owning scan has returned.
    public func release() async {
        if let persistent = enrichment as? PersistentFaceAnalysisProducer {
            await persistent.release()
        } else if let producer = enrichment as? TransientFaceEmbeddingProducer {
            await producer.release()
        }
    }
}
