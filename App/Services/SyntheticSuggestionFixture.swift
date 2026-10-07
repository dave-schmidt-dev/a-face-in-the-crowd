#if DEBUG
import Foundation
import AFITCCore

/// UI-test-only vector source for the generated synthetic fixture (`--uitest-synthetic-suggestions`,
/// which also requires `--uitest-synthetic-source`). It never loads a model and never reads bytes:
/// each fictional face gets a fixed unit vector chosen by its photo name and side, so the Verify
/// tests drive the production fence, index, engine and review queue with known outcomes.
///
/// Fixture photos `nested/synthetic-0...2.jpg` each carry a left (x < 0.5) and a right face.
/// Axis 0 and axis 1 are the two clusters; every face also has its own remainder axis so no two
/// candidates share anything outside the cluster axes.
/// - synthetic-0: left = pure cluster 0, right = pure cluster 1 (the faces tests name as examples).
/// - synthetic-1: left = cluster 0 at 0.95, right = cluster 1 at 0.90 (two clear suggestions).
/// - synthetic-2: left = near tie 0.70 / 0.68 (always ambiguous, never shown), right = cluster 1 at 0.80.
struct SyntheticFaceVectorProducer: FaceVectorProducing {
    static let launchArgument = "--uitest-synthetic-suggestions"
    static func isRequested(_ launch: LaunchOptions) -> Bool { launch.has(launchArgument) }

    /// Same identity the engine ranks with, so synthetic vectors take the production path.
    let manifest = ModelManifest.openCVSFace2021December

    func produce(_ request: ScanEnrichmentRequest,
                 progress: @escaping ScanEnrichmentProgress) async throws -> FaceVectorProduction {
        try Task.checkCancellation()
        let photo = Self.photoNumber(request.photo.relativePath)
        var vectors: [UUID: EmbeddingVector] = [:]
        for face in request.photo.analysis.faces {
            guard let photo, let x = face.rectangle.first,
                  let parts = Self.components(photo: photo, left: x < 0.5) else { continue }
            let dimension = manifest.outputShape.last ?? 128
            vectors[face.id] = EmbeddingVector(modelIdentifier: manifest.identifier,
                                               values: (0..<dimension).map { parts[$0] ?? 0 })
        }
        return FaceVectorProduction(photoID: request.photo.id, contentVersion: request.photo.contentVersion,
                                    contentHash: request.contentHash, vectors: vectors)
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

extension FaceEmbeddingCoordinator {
    /// Synthetic runs never build the model-backed producer. With the fixture flag and the toggle
    /// on, the scan carries a `FaceJobCoordinator` around `SyntheticFaceVectorProducer` through the
    /// same `prepareJob` handoff as production; otherwise nil keeps the scan unchanged.
    func syntheticSuggestionJob(repository: CatalogRepository) -> (any ScanEnrichment)? {
        guard let suggestions, SyntheticFaceVectorProducer.isRequested(suggestions.launch), let jobs = suggestions.prepareJob() else { return nil }
        return FaceJobCoordinator(repository: repository, producer: SyntheticFaceVectorProducer(),
                                  index: jobs.index, gate: jobs.gate, stats: jobs.stats)
    }
}
#endif
