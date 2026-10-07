import Foundation

/// Raw per-face vectors produced from one accepted photo's already verified bytes.
/// Keyed by the detected face geometry identifier; never Codable, persisted or logged.
public struct FaceVectorProduction: Sendable {
    public let photoID: UUID
    public let contentVersion: Int
    public let contentHash: String
    public let vectors: [UUID: EmbeddingVector]
    public init(photoID: UUID, contentVersion: Int, contentHash: String, vectors: [UUID: EmbeddingVector]) {
        self.photoID = photoID; self.contentVersion = contentVersion
        self.contentHash = contentHash; self.vectors = vectors
    }
}

/// Producer-side freshness failure: the result is discarded quietly, never reported as a scan failure.
public enum FaceVectorProductionError: Error, Sendable, Equatable { case stale }

/// Model-backed (or synthetic) vector source used by `FaceJobCoordinator`. It receives the scan's
/// request and must never reopen or reread the original.
public protocol FaceVectorProducing: Sendable {
    /// Model and preprocessing identity for every vector this producer returns.
    var manifest: ModelManifest { get }
    /// Returns vectors for `request.photo`, or throws `FaceVectorProductionError.stale` when superseded.
    func produce(_ request: ScanEnrichmentRequest, progress: @escaping ScanEnrichmentProgress) async throws -> FaceVectorProduction
    /// True when this photo deserves one admitted catch-up read of unchanged bytes.
    func needsAdmittedRead(_ photo: PhotoIdentity) async -> Bool
}

extension FaceVectorProducing {
    /// Default: producers without durable analysis never admit an extra source read.
    public func needsAdmittedRead(_ photo: PhotoIdentity) async -> Bool { false }
}

/// Fixed user-facing reasons a suggestion job skipped a photo. Skips never fail the scan.
public enum FaceJobPauseReason: String, Sendable, Equatable {
    case disabled = "Suggestion jobs are off."
    case thermal = "Suggestion jobs paused: device is warm"
    case memory = "Suggestion jobs paused: memory is low"
}

/// Per-photo admission check for suggestion jobs.
public protocol FaceJobResourceGate: Sendable {
    /// Returns nil when a job may run now, otherwise the fixed reason to show.
    func pauseReason() -> FaceJobPauseReason?
}

/// Session-only gate: evaluation toggle (default off), thermal state below `.serious`, and a
/// memory-warning latch that stays closed until explicitly cleared.
public final class FaceJobResources: FaceJobResourceGate, @unchecked Sendable {
    private let lock = NSLock()
    private let thermalState: @Sendable () -> ProcessInfo.ThermalState
    private var enabled = false
    private var memoryWarning = false

    /// `thermalState` is injectable for tests; production reads the process thermal state.
    public init(thermalState: @escaping @Sendable () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState }) {
        self.thermalState = thermalState
    }

    /// Evaluation suggestions toggle; session-only and off by default.
    public var isEnabled: Bool {
        get { lock.withLock { enabled } }
        set { lock.withLock { enabled = newValue } }
    }
    /// Closes the gate after a memory warning until `clearMemoryWarning()`.
    public func latchMemoryWarning() { lock.withLock { memoryWarning = true } }
    /// Reopens the memory-warning latch.
    public func clearMemoryWarning() { lock.withLock { memoryWarning = false } }

    public func pauseReason() -> FaceJobPauseReason? {
        let (enabled, memoryWarning) = lock.withLock { (self.enabled, self.memoryWarning) }
        guard enabled else { return .disabled }
        if memoryWarning { return .memory }
        return thermalState().rawValue < ProcessInfo.ThermalState.serious.rawValue ? nil : .thermal
    }
}

/// Counts and durations only: no names, paths, identifiers or vectors.
public struct FaceJobStatsSnapshot: Sendable, Equatable {
    /// Inference durations in seconds, oldest first, at most `FaceJobStats.window`.
    public var durations: [Double] = []
    public var p50: Double?
    public var p95: Double?
    // Per-photo outcome counts and the last fixed pause reason.
    public var indexedPhotos = 0
    public var indexedFaces = 0
    public var skippedAlreadyIndexed = 0
    /// Photos with no detected faces: nothing to infer or index.
    public var skippedNoFaces = 0
    /// Photos with faces but no vector the producer could embed; attempted once per session.
    public var skippedNoVectors = 0
    public var paused = 0
    public var discarded = 0
    public var failed = 0
    public var indexFull = 0
    public var lastPauseReason: FaceJobPauseReason?
}

/// Lock-protected rolling job statistics, readable synchronously from any actor.
public final class FaceJobStats: @unchecked Sendable {
    /// Number of most recent durations retained for percentiles.
    public static let window = 50
    private let lock = NSLock()
    private var value = FaceJobStatsSnapshot()

    public init() {}

    /// Consistent copy of the current counts and durations.
    public var snapshot: FaceJobStatsSnapshot { lock.withLock { value } }

    /// Nearest-rank percentile over `samples`; nil when empty.
    public static func percentile(_ p: Double, of samples: [Double]) -> Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let rank = Int((p * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }

    func record(duration: Double) {
        lock.withLock {
            value.durations.append(max(0, duration))
            if value.durations.count > Self.window { value.durations.removeFirst(value.durations.count - Self.window) }
            value.p50 = Self.percentile(0.5, of: value.durations)
            value.p95 = Self.percentile(0.95, of: value.durations)
        }
    }

    func update(_ body: (inout FaceJobStatsSnapshot) -> Void) { lock.withLock { body(&value) } }
}

/// Evaluation-only suggestion job that rides the existing serial scan as its enrichment hook,
/// so it never opens a second source-reading path. Each photo's vectors are indexed only if the
/// face pipeline fence captured before production still validates after it.
public actor FaceJobCoordinator: ScanEnrichment {
    private let repository: CatalogRepository
    private let producer: any FaceVectorProducing
    private let index: any FaceVectorIndex
    private let gate: any FaceJobResourceGate
    private let clock: @Sendable () -> TimeInterval
    /// Counts and durations for the Verify surface; never names, paths or vectors.
    public nonisolated let stats: FaceJobStats

    /// `clock` returns monotonic seconds and is injectable for tests.
    public init(repository: CatalogRepository, producer: any FaceVectorProducing, index: any FaceVectorIndex,
                gate: any FaceJobResourceGate, stats: FaceJobStats = FaceJobStats(),
                clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.repository = repository; self.producer = producer; self.index = index
        self.gate = gate; self.stats = stats; self.clock = clock
    }

    /// The suggestion gate also governs the one admitted catch-up read: a paused or disabled job
    /// never starts source work. Naming and group viewing cause zero reads and zero inference.
    public func needsAdmittedRead(_ photo: PhotoIdentity) async -> Bool {
        guard gate.pauseReason() == nil else { return false }
        let admitted = await producer.needsAdmittedRead(photo)
        return admitted && !Task.isCancelled && gate.pauseReason() == nil
    }

    /// Skips (closed gate, already indexed, stale) return normally; cancellation drains the producer
    /// and then throws without indexing; other producer errors are counted and rethrown so the scan
    /// reports its existing per-photo unavailable text.
    public func enrich(_ request: ScanEnrichmentRequest, progress: @escaping ScanEnrichmentProgress) async throws {
        try Task.checkCancellation()
        if let reason = gate.pauseReason() { return await pause(reason, progress) }
        // Read before any work for this photo: an invalidation after this point discards the result.
        let epoch = index.epoch
        let fence: CatalogFacePipelineFence
        do {
            fence = try await repository.captureFacePipelineFence(photo: request.photo, sourceIdentity: request.sourceIdentity)
        } catch is CancellationError { throw CancellationError() }
        catch { stats.update { $0.discarded += 1 }; return }
        guard fence.contentHash == request.contentHash else { stats.update { $0.discarded += 1 }; return }
        let manifest = producer.manifest
        if fence.faces.isEmpty {
            // A durable producer records empty-success using the already verified bytes;
            // legacy/synthetic producers retain their zero-work path.
            if await producer.needsAdmittedRead(request.photo) {
                _ = try await producer.produce(request, progress: progress)
            }
            stats.update { $0.skippedNoFaces += 1 }; return
        }
        if index.wasAttempted(photoID: fence.photoID, contentHash: request.contentHash, manifest: manifest) {
            stats.update { $0.skippedAlreadyIndexed += 1 }; return
        }

        let started = clock()
        let production: FaceVectorProduction
        do {
            production = try await producer.produce(request, progress: progress)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if error as? FaceVectorProductionError == .stale { stats.update { $0.discarded += 1 }; return }
            stats.update { $0.failed += 1 }
            throw error
        }
        stats.record(duration: clock() - started)
        try Task.checkCancellation()
        guard production.photoID == fence.photoID, production.contentVersion == fence.contentVersion,
              production.contentHash == request.contentHash else { stats.update { $0.discarded += 1 }; return }
        do {
            try await repository.validateFacePipelineFence(fence, sourceIdentity: request.sourceIdentity,
                                                           verifiedContentHash: request.contentHash)
        } catch is CancellationError { throw CancellationError() }
        catch { stats.update { $0.discarded += 1 }; return }
        try publish(production, fence: fence, manifest: manifest, epoch: epoch)
    }

    /// Synchronous from the last checks through the batch insert: nothing awaits in between. The
    /// index admits the whole photo atomically, only if it was not invalidated since `epoch` was read
    /// and capacity allows every face, so a photo is never left partly indexed.
    private func publish(_ production: FaceVectorProduction, fence: CatalogFacePipelineFence,
                         manifest: ModelManifest, epoch: UInt64) throws {
        try Task.checkCancellation()
        if gate.pauseReason() != nil { stats.update { $0.discarded += 1 }; return }
        let ready = fence.faces.compactMap { face in
            production.vectors[face.geometry.id].map { (face: face.key, vector: $0) }
        }
        let outcome: FaceVectorBatchResult
        do {
            outcome = try index.insert(ready, photoID: fence.photoID, contentHash: production.contentHash,
                                       manifest: manifest, epoch: epoch)
        }
        catch { stats.update { $0.failed += 1 }; throw error }
        switch outcome {
        case .inserted(0): stats.update { $0.skippedNoVectors += 1 }
        case .inserted(let count): stats.update { $0.indexedPhotos += 1; $0.indexedFaces += count }
        case .stale: stats.update { $0.discarded += 1 }
        case .full: stats.update { $0.indexFull += 1 }
        }
    }

    private func pause(_ reason: FaceJobPauseReason, _ progress: ScanEnrichmentProgress) async {
        stats.update { $0.paused += 1; $0.lastPauseReason = reason }
        await progress(reason.rawValue)
    }
}
