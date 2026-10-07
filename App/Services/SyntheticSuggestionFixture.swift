#if DEBUG
import Foundation
import AFITCCore
import AFITCRuntime

/// UI-test-only vector source for the generated synthetic fixture (`--uitest-synthetic-source`).
/// It never loads a model and never reads bytes: each fictional face gets a fixed unit vector
/// chosen by its photo name and side, so the tests drive the production reuse, admission,
/// resource-gate and fenced persistence path with known outcomes.
///
/// Fixture photos `nested/synthetic-0...2.jpg` each carry a left (x < 0.5) and a right face.
/// Axis 0 and axis 1 are the two clusters; every face also has its own remainder axis so no two
/// candidates share anything outside the cluster axes.
/// - synthetic-0: left = pure cluster 0, right = pure cluster 1 (the faces tests name as examples).
/// - synthetic-1: left = cluster 0 at 0.95, right = cluster 1 at 0.90 (two clear suggestions).
/// - synthetic-2: left = near tie 0.70 / 0.68 (always ambiguous, never shown), right = cluster 1 at 0.80.
struct SyntheticFaceVectorProducer {
    /// Same identity the engine ranks with, so synthetic vectors take the production path.
    static let manifest = ModelManifest.openCVSFace2021December

    /// Fictional vectors for one photo's faces; faces outside the fixture get none.
    static func vectors(for request: ScanEnrichmentRequest) -> [UUID: EmbeddingVector] {
        let photo = photoNumber(request.photo.relativePath)
        var vectors: [UUID: EmbeddingVector] = [:]
        for face in request.photo.analysis.faces {
            guard let photo, let x = face.rectangle.first,
                  let parts = components(photo: photo, left: x < 0.5) else { continue }
            let dimension = manifest.outputShape.last ?? 128
            vectors[face.id] = EmbeddingVector(modelIdentifier: manifest.identifier,
                                               values: (0..<dimension).map { parts[$0] ?? 0 })
        }
        return vectors
    }

    /// `nested/synthetic-N.jpg` -> N; anything else gets no vectors.
    static func photoNumber(_ path: String) -> Int? {
        let name = (path as NSString).lastPathComponent
        guard name.hasPrefix("synthetic-"), name.hasSuffix(".jpg") else { return nil }
        return Int(name.dropFirst("synthetic-".count).dropLast(".jpg".count))
    }

    /// Unit-length components for one fictional face, or nil for faces outside the fixture.
    static func components(photo: Int, left: Bool) -> [Int: Float]? {
        let cluster: [Int: Float]
        switch (photo, left) {
        case (0, true): cluster = [0: 1]
        case (0, false): cluster = [1: 1]
        case (1, true): cluster = [0: 0.95]
        case (1, false): cluster = [1: 0.90]
        case (2, true): cluster = [0: 0.70, 1: 0.68]
        case (2, false): cluster = [1: 0.80]
        default: return nil
        }
        let used = cluster.values.reduce(Float(0)) { $0 + $1 * $1 }
        guard used < 1 else { return cluster }
        var parts = cluster
        parts[10 + photo * 2 + (left ? 0 : 1)] = (1 - used).squareRoot()
        return parts
    }
}

/// Counts actual fictional vector computations so tests can prove durable reuse: a later scan
/// of unchanged bytes must not compute again.
enum SyntheticAnalysisProbe {
    private static let lock = NSLock()
    private static var count = 0
    private static var scans = 0
    private static var reads = 0
    static var scanCount: Int { lock.lock(); defer { lock.unlock() }; return scans }
    static var sourceReadCount: Int { lock.lock(); defer { lock.unlock() }; return reads }
    static func recordScan() { lock.lock(); defer { lock.unlock() }; scans += 1 }
    static func recordRead() { lock.lock(); defer { lock.unlock() }; reads += 1 }
    static var computationCount: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
    static func recordComputation() {
        lock.lock(); defer { lock.unlock() }
        count += 1
    }
    static func reset() {
        lock.lock(); defer { lock.unlock() }
        count = 0; scans = 0; reads = 0
    }
}

/// Durable synthetic producer: mirrors `PersistentFaceAnalysisProducer` so the fixture's fixed
/// fictional vectors persist through the same reuse, admission, resource-gate and fenced
/// transaction as production analysis. There is no toggle: an ordinary scan of the fixture
/// computes and persists them exactly once.
actor SyntheticPersistentAnalysisProducer: ScanEnrichment {
    let manifest = SyntheticFaceVectorProducer.manifest
    private let repository: CatalogRepository
    private let gate: (any FaceJobResourceGate)?

    init(repository: CatalogRepository, gate: (any FaceJobResourceGate)? = nil) {
        self.repository = repository
        self.gate = gate
    }

    /// True when this photo deserves exactly one admitted catch-up read of its unchanged bytes.
    func needsAdmittedRead(_ photo: PhotoIdentity) async -> Bool {
        guard !Task.isCancelled, gate?.pauseReason() == nil else { return false }
        return (try? await repository.needsAdmittedAnalysisRead(photo: photo, manifest: manifest)) == true
    }

    func enrich(_ request: ScanEnrichmentRequest, progress: @escaping ScanEnrichmentProgress) async throws {
        // Accepted current analysis for the actual current photo/source binding: no work.
        if (try? await repository.satisfiesAnalysisReuse(photo: request.photo, manifest: manifest)) == true { return }
        // Failure, pause and capacity-full require an explicit retry admission.
        guard try await repository.needsAdmittedAnalysisRead(photo: request.photo, manifest: manifest) else { return }
        if let reason = gate?.pauseReason() {
            await progress(reason.rawValue.replacingOccurrences(of: "Suggestion jobs", with: "Face analysis"))
            return
        }
        try Task.checkCancellation()
        let computed = SyntheticFaceVectorProducer.vectors(for: request)
        SyntheticAnalysisProbe.recordComputation()
        guard let fence = try? await repository.captureFaceAnalysisPersistenceFence(
            photo: request.photo, sourceIdentity: request.sourceIdentity),
            fence.contentHash == request.contentHash else {
            throw TransientFaceEmbeddingError.stale
        }
        let status: PhotoAnalysisStatus
        let reason: String?
        if request.photo.analysis.faces.isEmpty {
            status = .emptySuccess; reason = nil
        } else if computed.isEmpty {
            status = .failed; reason = "No face details could be computed for this photo."
        } else {
            status = .completed; reason = nil
        }
        // The minimal fence is revalidated inside this transaction; a changed generation,
        // rebound source or suppressed face cannot publish stale fictional vectors.
        try Task.checkCancellation()
        guard gate?.pauseReason() == nil else { return }
        let vectors = computed.map { (faceID: $0.key, vector: $0.value) }
        let outcome = try await repository.saveFaceAnalysisBatch(fence: fence,
                                                                 verifiedContentHash: request.contentHash,
                                                                 vectors: vectors, manifest: manifest,
                                                                 status: status, reason: reason)
        if outcome == .stale { throw TransientFaceEmbeddingError.stale }
    }
}
#endif
