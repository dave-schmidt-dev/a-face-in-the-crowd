import AFITCCore
import Foundation

/// Durable per-scan analysis producer: wraps the pinned transient producer and persists its
/// result through the repository's fenced transaction. Reuse is decided against the actual
/// current catalog photo and source binding before any model work, so an accepted current
/// analysis causes zero reads and zero inference on later scans of unchanged bytes.
public actor PersistentFaceAnalysisProducer: ScanEnrichment {
    private let producer: TransientFaceEmbeddingProducer
    private let repository: CatalogRepository
    private let store: TransientFaceEmbeddingStore
    private let gate: (any FaceJobResourceGate)?
    public let manifest: ModelManifest

    public init(producer: TransientFaceEmbeddingProducer, repository: CatalogRepository,
                store: TransientFaceEmbeddingStore,
                manifest: ModelManifest = .openCVSFace2021December, gate: (any FaceJobResourceGate)? = nil) {
        self.producer = producer; self.repository = repository; self.store = store
        self.manifest = manifest; self.gate = gate
    }

    /// Drops the wrapped producer's model handles after the owning scan has returned.
    public func release() async { await producer.release() }

    /// True when this photo deserves exactly one admitted catch-up read of its unchanged bytes.
    /// Database trouble never admits a read; the ordinary scan path still verifies bytes itself.
    public func needsAdmittedRead(_ photo: PhotoIdentity) async -> Bool {
        guard !Task.isCancelled, gate?.pauseReason() == nil else { return false }
        guard let needed = try? await repository.needsAdmittedAnalysisRead(photo: photo, manifest: manifest) else {
            return false
        }
        guard needed else { return false }
        guard await producer.prepareForCatchUp(photo) else { return false }
        // Model preparation may await: recheck admission against the current catalog afterwards.
        guard !Task.isCancelled, gate?.pauseReason() == nil else { return false }
        return (try? await repository.needsAdmittedAnalysisRead(photo: photo, manifest: manifest)) == true
    }

    public func enrich(_ request: ScanEnrichmentRequest, progress: @escaping ScanEnrichmentProgress) async throws {
        // Accepted current analysis for the actual current photo/source binding: no model work.
        let reused = (try? await repository.satisfiesAnalysisReuse(photo: request.photo, manifest: manifest)) ?? false
        if reused { return }
        // Failure, pause and capacity-full require an explicit retry admission even if the
        // ordinary scan already read bytes for integrity or preview recovery.
        guard try await repository.needsAdmittedAnalysisRead(photo: request.photo, manifest: manifest) else { return }
        if let reason = gate?.pauseReason() {
            await progress(reason.rawValue.replacingOccurrences(of: "Suggestion jobs", with: "Face analysis"))
            return
        }
        do {
            try await producer.enrich(request, progress: progress)
        } catch let error as TransientFaceEmbeddingError {
            if error == .pipelineFailed {
                // An explicit durable failure state keeps later ordinary scans from rereading
                // unchanged bytes; it never becomes empty-success.
                try? await recordFailure(request)
            }
            throw error
        }
        guard let batch = store.latestBatch, batch.photoID == request.photo.id,
              batch.contentVersion == request.photo.contentVersion,
              batch.fence.contentHash == request.contentHash,
              batch.sFaceModelIdentifier == manifest.identifier else {
            throw TransientFaceEmbeddingError.stale
        }
        var vectors: [(faceID: UUID, vector: EmbeddingVector)] = []
        for row in batch.rows {
            guard case .embedded(let result, _) = row.outcome else { continue }
            vectors.append((faceID: row.visionFaceID, vector: result.embedding))
        }
        let status: PhotoAnalysisStatus
        let reason: String?
        if batch.rows.isEmpty {
            status = .emptySuccess; reason = nil
        } else if vectors.isEmpty {
            status = .failed; reason = "No face details could be computed for this photo."
        } else {
            status = .completed; reason = nil
        }
        // The minimal fence is revalidated inside this transaction; a changed generation,
        // rebound source or suppressed face cannot publish stale biometric vectors.
        try Task.checkCancellation()
        guard gate?.pauseReason() == nil else { return }
        let outcome = try await repository.saveFaceAnalysisBatch(fence: batch.fence,
                                                                 verifiedContentHash: request.contentHash,
                                                                 vectors: vectors, manifest: manifest,
                                                                 status: status, reason: reason)
        if outcome == .stale { throw TransientFaceEmbeddingError.stale }
    }

    /// Records an explicit failed attempt for this exact generation, source and pipeline.
    private func recordFailure(_ request: ScanEnrichmentRequest) async throws {
        guard let fence = try? await repository.captureFaceAnalysisPersistenceFence(
            photo: request.photo, sourceIdentity: request.sourceIdentity) else { return }
        guard fence.contentHash == request.contentHash else { return }
        _ = try await repository.saveFaceAnalysisBatch(fence: fence, verifiedContentHash: request.contentHash,
                                                       vectors: [], manifest: manifest,
                                                       status: .failed, reason: "Face analysis failed.")
    }
}
