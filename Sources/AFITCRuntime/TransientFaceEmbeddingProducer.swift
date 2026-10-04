import AFITCCore
import Foundation

/// Why one existing Vision face has no transient embedding. Unavailable is not a negative claim.
public enum TransientFaceUnavailableReason: Equatable, Sendable {
    case association(FaceAlignmentUnavailableReason)
    case alignment(SFacePreprocessingError)
}

public enum TransientFaceEmbeddingOutcome: Equatable, Sendable {
    /// Raw SFace output exactly as returned, plus the YuNet points used for its crop.
    case embedded(FaceEmbeddingResult, points: SFaceFivePoints)
    case unavailable(TransientFaceUnavailableReason)
}

/// One row per existing Vision face UUID, in the accepted photo's fence order.
public struct TransientFaceEmbeddingRow: Equatable, Sendable {
    public let visionFaceID: UUID
    public let outcome: TransientFaceEmbeddingOutcome
}

/// Latest single-photo result, held only in RAM. Deliberately not Codable: it is never
/// persisted, cached, matched, labeled or treated as confirmation or identity.
public struct TransientFaceEmbeddingBatch: Sendable {
    public let fence: CatalogFacePipelineFence
    public let sourceIdentity: String?
    public let operationID: UUID
    public let sessionEpoch: UInt64
    public let yuNetModelIdentifier: String
    public let sFaceModelIdentifier: String
    public let rows: [TransientFaceEmbeddingRow]
    public var photoID: UUID { fence.photoID }
    public var contentVersion: Int { fence.contentVersion }

    /// The publication fence proved one transaction instant. Any later use must revalidate
    /// against caller-verified bytes; success grants no persisted-write authority.
    public func revalidate(in repository: CatalogRepository, verifiedContentHash: String) async throws {
        try await repository.validateFacePipelineFence(fence, sourceIdentity: sourceIdentity,
                                                       verifiedContentHash: verifiedContentHash)
    }
}

public enum TransientFaceEmbeddingError: Error, Equatable, Sendable {
    case ineligible
    case modelsUnavailable
    case stale
    case pipelineFailed
}

/// Opaque admission token for one scan operation; clearing the store invalidates it.
public struct TransientFaceEmbeddingToken: Equatable, Sendable {
    let generation: UInt64
    public let operationID: UUID
    public let sessionEpoch: UInt64
}

/// Lock-protected RAM holder shared by the MainActor App facade and runtime workers.
/// `invalidate()` is synchronous: it advances the token generation and drops the batch, so a
/// completion that already passed every await cannot publish afterwards.
public final class TransientFaceEmbeddingStore: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var batch: TransientFaceEmbeddingBatch?

    public init() {}

    public var latestBatch: TransientFaceEmbeddingBatch? { lock.withLock { batch } }

    public func invalidate() { lock.withLock { generation &+= 1; batch = nil } }

    public func isCurrent(_ token: TransientFaceEmbeddingToken) -> Bool {
        lock.withLock { token.generation == generation }
    }

    func begin(operationID: UUID, sessionEpoch: UInt64) -> TransientFaceEmbeddingToken {
        lock.withLock {
            generation &+= 1; batch = nil
            return TransientFaceEmbeddingToken(generation: generation, operationID: operationID,
                                               sessionEpoch: sessionEpoch)
        }
    }

    /// Replaces the single retained batch only while the producing token is still current.
    func publish(_ value: TransientFaceEmbeddingBatch, for token: TransientFaceEmbeddingToken) -> Bool {
        lock.withLock {
            guard token.generation == generation else { return false }
            batch = value
            return true
        }
    }

    /// The App's only construction path. Synthetic fixtures bypass trained models entirely.
    public func makeEnrichment(repository: CatalogRepository, operationID: UUID, sessionEpoch: UInt64,
                               syntheticFixture: Bool) -> TransientFaceEmbeddingProducer? {
        guard !syntheticFixture else { invalidate(); return nil }
        return TransientFaceEmbeddingProducer(repository: repository, store: self,
            token: begin(operationID: operationID, sessionEpoch: sessionEpoch),
            loader: BundledFacePipelineModelLoader())
    }
}

struct FacePipelineModels: Sendable {
    let yuNet: YuNetRuntime
    let sFace: FaceEmbeddingRuntime
}

protocol FacePipelineModelLoader: Sendable {
    func load() async throws -> FacePipelineModels
}

/// Resolves the immutable pinned bundle resources off the caller's actor, then prepares both
/// CPU runtimes. Each preparation re-verifies its pinned artifact before creating a session.
struct BundledFacePipelineModelLoader: FacePipelineModelLoader {
    func load() async throws -> FacePipelineModels {
        let urls = try await TransientFaceEmbeddingProducer.joined {
            (try BundledModelResources.verify(.yuNet2023Mar).url, try BundledModelResources.verify(.sface2021Dec).url)
        }
        return try await LocalFacePipelineModelLoader(yuNetURL: urls.0, sFaceURL: urls.1).load()
    }
}

/// Explicit local model locations; used by the bundled loader and the opt-in host diagnostic.
struct LocalFacePipelineModelLoader: FacePipelineModelLoader {
    let yuNetURL: URL
    let sFaceURL: URL
    func load() async throws -> FacePipelineModels {
        let yuNet = try await YuNetModelPreparation().prepare(at: yuNetURL)
        let sFace = try await ModelPreparation().prepare(at: sFaceURL)
        return FacePipelineModels(yuNet: yuNet, sFace: sFace)
    }
}

/// Production per-scan producer: canonical oriented RGB, fixed-640 BGR tensor, pinned YuNet
/// heads, strict decode and inverse geometry, unique association to existing Vision UUIDs,
/// SFace five-point crop and raw 128-value output. It never writes the catalog.
public actor TransientFaceEmbeddingProducer: ScanEnrichment {
    private let repository: CatalogRepository
    private let store: TransientFaceEmbeddingStore
    private let token: TransientFaceEmbeddingToken
    private let loader: any FacePipelineModelLoader
    private var models: FacePipelineModels?
    private var preparationFailed = false
    private var released = false

    init(repository: CatalogRepository, store: TransientFaceEmbeddingStore,
         token: TransientFaceEmbeddingToken, loader: any FacePipelineModelLoader) {
        self.repository = repository; self.store = store; self.token = token; self.loader = loader
    }

    var hasPreparedModels: Bool { models != nil }

    /// Drops model handles after the owning scan has returned; later requests are stale.
    public func release() { models = nil; released = true }

    public func enrich(_ request: ScanEnrichmentRequest, progress: @escaping ScanEnrichmentProgress) async throws {
        let store = self.store, token = self.token
        let current: @Sendable () -> Bool = { store.isCurrent(token) }
        let report: ScanEnrichmentProgress = { message in if current() { await progress(message) } }
        do {
            try await produce(request, current: current, report: report)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            switch error {
            case let known as TransientFaceEmbeddingError: throw known
            case is FacePipelineFenceError, YuNetRuntimeError.staleProvenance,
                 FaceEmbeddingRuntimeError.staleProvenance: throw TransientFaceEmbeddingError.stale
            default: throw TransientFaceEmbeddingError.pipelineFailed
            }
        }
    }

    private func produce(_ request: ScanEnrichmentRequest, current: @escaping @Sendable () -> Bool,
                         report: ScanEnrichmentProgress) async throws {
        try admit(current)
        let fence: CatalogFacePipelineFence
        do {
            fence = try await repository.captureFacePipelineFence(photo: request.photo,
                                                                  sourceIdentity: request.sourceIdentity)
        } catch FacePipelineFenceError.ineligible { throw TransientFaceEmbeddingError.ineligible }
        guard fence.contentHash == request.contentHash else { throw TransientFaceEmbeddingError.stale }
        let vision = try fence.faces.map { face -> FaceAlignmentVisionFace in
            let r = face.geometry.rectangle
            guard r.count == 4 else { throw TransientFaceEmbeddingError.ineligible }
            return FaceAlignmentVisionFace(faceID: face.geometry.id,
                box: FaceAlignmentNormalizedBox(x: r[0], y: r[1], width: r[2], height: r[3]))
        }
        guard !vision.isEmpty else {
            // Zero accepted faces: neither trained model is prepared or run.
            try await publish(fence, request, rows: [], models: nil, current: current)
            return
        }
        if models == nil, !preparationFailed { await report("Preparing on-device face models for face details.") }
        let models = try await preparedModels()
        try admit(current)
        await report("Finding face details for this photo.")
        let bytes = request.bytes
        let (raster, prepared) = try await Self.joined { () -> (RGB8Raster, YuNet640PreparedInput) in
            let raster = try JPEGPreviewDecoder.canonicalRGB(bytes)
            return (raster, try YuNetRasterPreprocessor.prepare(raster: raster))
        }
        try admit(current)
        let frame = FaceAlignmentFrame(photoID: fence.photoID, contentVersion: fence.contentVersion,
                                       rasterWidth: raster.width, rasterHeight: raster.height,
                                       operationToken: token.operationID)
        let transform = try YuNetGeometryTransform(frame: frame)
        guard Self.matches(transform, prepared.geometry) else { throw TransientFaceEmbeddingError.pipelineFailed }
        let input = prepared.modelInput
        let detected = try await models.yuNet.infer(
            from: YuNetRuntimeTensor(name: YuNetRuntimeContract.inputName, elementType: .float32,
                                     shape: input.shape, values: input.values),
            provenance: YuNetRuntimeProvenance(photoID: fence.photoID, contentVersion: fence.contentVersion,
                                               detectorVersion: fence.detectorVersion,
                                               operationID: token.operationID, sessionEpoch: token.sessionEpoch),
            isCurrent: { _ in current() })
        try admit(current)
        let decoded = try YuNetTensorDecoder.decode(outputs: detected.outputs.map(Self.named))
        let mapped = try transform.map(decoded)
        let association = FaceAlignmentAssociator.associate(
            currentFrame: frame, expectedVisionDetectorRevision: fence.detectorVersion,
            expectedYuNetDetectorRevision: YuNetRuntimeContract.identifier,
            vision: FaceAlignmentVisionInput(frame: frame, detectorRevision: fence.detectorVersion, faces: vision),
            yuNet: FaceAlignmentYuNetInput(frame: frame, detectorRevision: YuNetRuntimeContract.identifier,
                                           faces: mapped.map(\.geometry)))
        let manifest = models.sFace.manifest
        let total = association.rows.filter { if case .available = $0.resolution { return true }; return false }.count
        var rows: [TransientFaceEmbeddingRow] = []
        var started = 0
        for row in association.rows {
            guard case .available(let points) = row.resolution else {
                if case .unavailable(let reason) = row.resolution {
                    rows.append(TransientFaceEmbeddingRow(visionFaceID: row.visionFaceID,
                                                          outcome: .unavailable(.association(reason))))
                }
                continue
            }
            try admit(current)
            let face: SFacePreprocessedFace
            do { face = try SFacePreprocessor.prepare(raster: raster, points: points) }
            catch let error as SFacePreprocessingError {
                rows.append(TransientFaceEmbeddingRow(visionFaceID: row.visionFaceID,
                                                      outcome: .unavailable(.alignment(error))))
                continue
            }
            started += 1
            await report("Computing face details for face \(started) of \(total).")
            let provenance = FaceEmbeddingProvenance(
                photoID: fence.photoID, contentVersion: fence.contentVersion, faceID: row.visionFaceID,
                detectorVersion: fence.detectorVersion, operationID: token.operationID,
                sessionEpoch: token.sessionEpoch, modelIdentifier: manifest.identifier,
                preprocessingVersion: manifest.preprocessingVersion)
            let result = try await models.sFace.embedding(from: face.modelInput, provenance: provenance,
                                                          isCurrent: { _ in current() })
            rows.append(TransientFaceEmbeddingRow(visionFaceID: row.visionFaceID,
                                                  outcome: .embedded(result, points: points)))
        }
        try await publish(fence, request, rows: rows, models: models, current: current)
        let embedded = rows.filter { if case .embedded = $0.outcome { return true }; return false }.count
        await report("Face details ready for \(embedded) of \(rows.count) detected faces in this photo.")
    }

    /// Revalidates the saved domain with the same verified hash after every await, then
    /// publishes only if the App token is still current at that synchronous instant.
    private func publish(_ fence: CatalogFacePipelineFence, _ request: ScanEnrichmentRequest,
                         rows: [TransientFaceEmbeddingRow], models: FacePipelineModels?,
                         current: @Sendable () -> Bool) async throws {
        try admit(current)
        try await repository.validateFacePipelineFence(fence, sourceIdentity: request.sourceIdentity,
                                                       verifiedContentHash: request.contentHash)
        try admit(current)
        let batch = TransientFaceEmbeddingBatch(
            fence: fence, sourceIdentity: request.sourceIdentity, operationID: token.operationID,
            sessionEpoch: token.sessionEpoch, yuNetModelIdentifier: YuNetRuntimeContract.identifier,
            sFaceModelIdentifier: models?.sFace.manifest.identifier ?? ModelManifest.openCVSFace2021December.identifier,
            rows: rows)
        guard store.publish(batch, for: token) else { throw TransientFaceEmbeddingError.stale }
    }

    private func admit(_ current: () -> Bool) throws {
        try Task.checkCancellation()
        guard !released, current() else { throw TransientFaceEmbeddingError.stale }
    }

    /// Prepares once per scan. A non-cancellation failure is retained for this scan, so later
    /// photos report unavailable without rehashing the model files.
    private func preparedModels() async throws -> FacePipelineModels {
        if let models { return models }
        guard !preparationFailed else { throw TransientFaceEmbeddingError.modelsUnavailable }
        do {
            let loaded = try await loader.load()
            try Task.checkCancellation()
            guard !released else { throw TransientFaceEmbeddingError.stale }
            models = loaded
            return loaded
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if error as? TransientFaceEmbeddingError == .stale { throw error }
            preparationFailed = true
            throw TransientFaceEmbeddingError.modelsUnavailable
        }
    }

    /// Runs synchronous CPU work off this actor and joins it: cancellation is forwarded,
    /// and the caller still waits for the worker's actual return.
    static func joined<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        let work = Task.detached(priority: .userInitiated) { try body() }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    private static func named(_ tensor: YuNetRuntimeTensor) -> YuNetNamedTensor {
        let type: YuNetTensorElementType
        switch tensor.elementType {
        case .float32: type = .float32
        case .float16: type = .float16
        case .int32: type = .int32
        }
        return YuNetNamedTensor(name: tensor.name, elementType: type, shape: tensor.shape, values: tensor.values)
    }

    private static func matches(_ transform: YuNetGeometryTransform, _ geometry: YuNet640Geometry) -> Bool {
        transform.sourceFrame.rasterWidth == geometry.sourceWidth
            && transform.sourceFrame.rasterHeight == geometry.sourceHeight
            && transform.resizedWidth == geometry.resizedWidth && transform.resizedHeight == geometry.resizedHeight
            && transform.padLeft == geometry.padLeft && transform.padTop == geometry.padTop
            && transform.padRight == geometry.padRight && transform.padBottom == geometry.padBottom
            && transform.effectiveScaleX == geometry.effectiveScaleX
            && transform.effectiveScaleY == geometry.effectiveScaleY
    }
}
