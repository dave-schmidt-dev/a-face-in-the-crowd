import Foundation
import CryptoKit

public enum ScanPhase: String, Codable, Sendable { case ready, discovering, processing, completed, cancelled, paused, failed, interrupted, cancelling }
public struct ScanProgress: Codable, Sendable, Equatable {
    public var phase: ScanPhase = .ready
    public var discovered = 0
    public var processed = 0
    public var skipped = 0
    public var failed = 0
    public var enumerationFinished = false
    public var message: String?
    public init() {}
}
/// The exact accepted photo plus the bytes and hash this scan already read and verified.
/// Enrichment receives no source handle, so it cannot reopen or reread the original.
public struct ScanEnrichmentRequest: Sendable {
    public let photo: PhotoIdentity
    public let entry: SourceEntry
    public let sourceIdentity: String?
    public let bytes: Data
    public let contentHash: String
    public init(photo: PhotoIdentity, entry: SourceEntry, sourceIdentity: String?, bytes: Data, contentHash: String) {
        self.photo = photo; self.entry = entry; self.sourceIdentity = sourceIdentity
        self.bytes = bytes; self.contentHash = contentHash
    }
}
/// Fixed user-facing stage text routed to the existing scan progress surface.
public typealias ScanEnrichmentProgress = @Sendable (String) async -> Void
/// Optional awaited per-photo work after an accepted save. Ordinary errors never change saved state.
public protocol ScanEnrichment: Sendable {
    func enrich(_ request: ScanEnrichmentRequest, progress: @escaping ScanEnrichmentProgress) async throws
    /// True when this trusted unchanged photo deserves exactly one admitted catch-up read so
    /// enrichment can complete missing durable analysis from verified bytes.
    func needsAdmittedRead(_ photo: PhotoIdentity) async -> Bool
}

extension ScanEnrichment {
    /// Default: enrichment without durable analysis never admits an extra source read.
    public func needsAdmittedRead(_ photo: PhotoIdentity) async -> Bool { false }
}
/// Serial pull pipeline. Cached verified records precede any source integrity reads.
public actor ScanCoordinator {
    private let repository: CatalogRepository
    private var cancelled = false
    private var paused = false
    private var running = false
    private var current = ScanProgress()
    private var observer: (@Sendable (ScanProgress, PhotoIdentity?) async -> Void)?
    public init(repository: CatalogRepository) { self.repository = repository }
    public func cancel() async {
        cancelled = true
        if running {
            current.phase = .cancelling; current.message = "Cancellation requested. Finishing the bounded current operation."
            await observer?(current, nil)
        }
    }
    public func pause() { paused = true }
    /// `targets` (relative paths) limits the pass to those photos: others are skipped unseen, enumeration
    /// stops after the last target, nothing is marked missing and the persisted checkpoint is untouched.
    /// A targeted pass never rebinds the source (`confirmedSource` is ignored); unseen targets count as failed.
    public func scan(source: any PhotoSource, detector: any DetectionProvider, confirmedSource: Bool = false,
                     targets: Set<String>? = nil, enrichment: (any ScanEnrichment)? = nil, update: @escaping @Sendable (ScanProgress, PhotoIdentity?) async -> Void) async -> ScanProgress {
        var progress = ScanProgress()
        guard !running else { progress.phase = .failed; progress.message = "A scan is already running."; return progress }
        running = true; cancelled = false; paused = false; observer = update
        defer { running = false; observer = nil }
        var lease: Int?
        var previewRecoveryPending = false
        var pinnedCheckpoint: ScanProgress?  // targeted passes persist this instead of their own progress
        do {
            let cached = try await repository.photos()
            progress.phase = .discovering
            progress.message = "Opening source. Showing last verified catalog before integrity checks."
            await publish(progress, nil)
            for photo in cached where targets?.contains(photo.relativePath) ?? true { try checkStop(); await publish(progress, photo) }
            try checkStop()
            try await source.open()
            let identity = try await source.identity()
            lease = try await repository.acquireSource(identity: identity, confirmed: confirmedSource && targets == nil)
            let generation = lease!
            if targets != nil { pinnedCheckpoint = try await repository.checkpoint() ?? ScanProgress() }
            if let bookmark = try await source.permissionBookmark() {
                try await repository.storeGrant(bookmark, lease: generation)
            }
            progress.phase = .discovering
            try await repository.save(progress: pinnedCheckpoint ?? progress, lease: generation)
            await publish(progress, nil)
            let existing = Dictionary(uniqueKeysWithValues: cached.map { ($0.relativePath, $0) })
            var seen = Set<String>()
            var remaining = targets
            var previewsUnavailable = 0
            while true {
                try checkStop()
                try await repository.requireLease(generation)
                if remaining?.isEmpty == true { break }
                guard let entry = try await source.next() else { break }
                guard seen.insert(entry.relativePath).inserted else { continue }
                if remaining != nil, remaining?.remove(entry.relativePath) == nil { continue }
                progress.discovered += 1; progress.phase = .processing
                progress.message = "Checking source integrity. Cached previews show the last verified content."
                await publish(progress, nil)
                var photo = existing[entry.relativePath] ?? PhotoIdentity(relativePath: entry.relativePath)
                await publish(progress, photo)
                var readBytes: Data?
                var readHash: String?
                previewRecoveryPending = false
                do {
                    try checkStop()
                    try await repository.requireLease(generation)
                    let acceptedAnalysis = photo.analysis.status == .successful && photo.contentHash != nil
                    var previewAvailable = false
                    if acceptedAnalysis {
                        do { previewAvailable = try await repository.previewIsAvailable(photo.previewPath, for: photo.id) }
                        catch let error as ScanError where error == .staleLease { throw error }
                        catch { previewAvailable = false }
                        if !previewAvailable {
                            // Persist the truthful missing-cache context without changing accepted analysis.
                            photo.previewPath = nil
                            previewRecoveryPending = true
                            progress.message = "Cached preview unavailable. Accepted analysis remains while the source is checked."
                            try await repository.save(photo, progress: pinnedCheckpoint ?? progress, lease: generation)
                            await publish(progress, photo)
                        }
                    }
                    try await repository.checkStorage()
                    let trustworthy = entry.metadata?.revision != nil && entry.metadata?.revision == photo.metadata?.revision
                    if trustworthy, acceptedAnalysis, previewAvailable {
                        photo.missing = false; photo.verifiedAt = Date()
                        if let enrichment {
                            // One honest catch-up read for missing durable analysis; an accepted
                            // current analysis causes zero reads and zero inference here.
                            do {
                                if let admitted = try await admittedRead(enrichment, source: source,
                                                                         entry: entry, photo: photo,
                                                                         generation: generation, progress: &progress) {
                                    readBytes = admitted.bytes; readHash = admitted.hash
                                }
                            } catch is CancellationError { throw CancellationError() }
                            catch let error as ScanError where error == .paused || error == .staleLease { throw error }
                            catch {
                                // The admitted read is opportunistic: accepted analysis is
                                // preserved and the catch-up retries on a later scan.
                                progress.message = "Saved face details remain incomplete. The verified photo will be analyzed on a later scan."
                                await publish(progress, nil)
                            }
                        }
                    } else {
                        let bytes = try await source.read(entry)
                        readBytes = bytes
                        let hash = try digest(bytes)
                        readHash = hash
                        try checkStop()
                        let unchangedAcceptedAnalysis = hash == photo.contentHash && photo.analysis.status == .successful
                        if !unchangedAcceptedAnalysis {
                            if photo.contentHash != nil && hash != photo.contentHash {
                                // Old face UUIDs and their decisions remain tied to the old generation.
                                photo = PhotoIdentity(id: photo.id, relativePath: photo.relativePath, dateAdded: photo.dateAdded,
                                    contentVersion: try CatalogCounters.successor(photo.contentVersion, minimum: 1))
                            }
                            photo.contentHash = hash; photo.metadata = entry.metadata; photo.missing = false
                            photo.analysis = FaceAnalysisState(status: .pending, contentVersion: photo.contentVersion)
                            previewRecoveryPending = false
                            // Invalidation is durable before processing; interruption cannot resurrect old faces.
                            try await repository.save(photo, progress: pinnedCheckpoint ?? progress, lease: generation)
                            await publish(progress, photo)
                            progress.message = "Preparing preview and detecting faces."
                            await publish(progress, nil)
                            let result = try await detector.process(bytes, contentVersion: photo.contentVersion)
                            try checkStop()
                            try await repository.requireLease(generation)
                            guard result.analysis.contentVersion == photo.contentVersion else { throw ScanError.staleLease }
                            let previewPath = try await repository.storePreview(result.jpeg, id: photo.id,
                                generation: "\(photo.contentVersion)-\(generation)", lease: generation)
                            try checkStop()
                            try await repository.requireLease(generation)
                            photo.previewPath = previewPath
                            photo.analysis = result.analysis
                        } else if previewRecoveryPending {
                            try checkStop()
                            try await repository.requireLease(generation)
                            let preview: Data?
                            do { preview = try JPEGPreviewDecoder.jpeg(JPEGPreviewDecoder.decode(bytes)) }
                            catch { preview = nil }
                            if let preview {
                                do {
                                    try checkStop()
                                    try await repository.requireLease(generation)
                                    try await repository.checkStorage()
                                    let previewPath = try await repository.storePreview(preview, id: photo.id,
                                        generation: "\(photo.contentVersion)-\(generation)", lease: generation)
                                    try checkStop()
                                    try await repository.requireLease(generation)
                                    photo.previewPath = previewPath
                                    previewRecoveryPending = false
                                    progress.message = "Unchanged source verified. The missing preview was rebuilt without rerunning face analysis."
                                } catch let error as ScanError where error == .paused || error == .storagePressure || error == .unavailable || error == .denied || error == .staleLease {
                                    throw error
                                } catch is CancellationError { throw CancellationError() }
                                catch {
                                    photo.previewPath = nil
                                    progress.message = "Preview unavailable. Accepted analysis remains; resume to retry the rebuild."
                                    previewsUnavailable += 1
                                }
                            } else {
                                photo.previewPath = nil
                                progress.message = "Preview unavailable. Accepted analysis remains because the unchanged source could not be decoded."
                                previewsUnavailable += 1
                            }
                        }
                        // Weak metadata reads backfill source facts; unchanged cache recovery never changes analysis.
                        photo.captureDate = CaptureDateMetadata.extract(fromValidatedJPEG: bytes)
                        photo.metadata = entry.metadata; photo.contentHash = hash
                        photo.missing = false; photo.verifiedAt = Date()
                    }
                    progress.processed += 1
                } catch let error as CounterError { throw error }
                catch let error as ScanError where error == .malformed || error == .oversized || error == .unsafePath {
                    // Oversized or unsafe originals changed since acceptance; a missing preview never shields them.
                    if previewRecoveryPending && error == .malformed {
                        photo.previewPath = nil
                        progress.message = "Preview unavailable. Accepted analysis remains; source verification will retry on resume."
                        progress.failed += 1; previewsUnavailable += 1
                    } else {
                        previewRecoveryPending = false
                        // Unreadable changed bytes must not retain an old confirmed face index.
                        if photo.analysis.status == .successful {
                            photo = PhotoIdentity(id: photo.id, relativePath: photo.relativePath, dateAdded: photo.dateAdded,
                                contentVersion: try CatalogCounters.successor(photo.contentVersion, minimum: 1))
                        }
                        photo.captureDate = nil
                        photo.analysis = FaceAnalysisState(status: .skipped, contentVersion: photo.contentVersion, reason: error.message)
                        progress.skipped += 1
                    }
                } catch let error as ScanError where error == .paused || error == .storagePressure || error == .unavailable || error == .denied || error == .staleLease {
                    if previewRecoveryPending {
                        progress.message = "Preview unavailable. Accepted analysis remains; resume after source or storage access is available."
                    }
                    throw error
                } catch is CancellationError {
                    if previewRecoveryPending {
                        progress.message = "Scan cancelled. Accepted analysis remains; preview recovery will retry when resumed."
                    }
                    throw CancellationError()
                } catch {
                    if previewRecoveryPending {
                        photo.previewPath = nil
                        progress.message = "Preview unavailable. Accepted analysis remains; source or cache recovery can be retried."
                        progress.failed += 1; previewsUnavailable += 1
                    } else {
                        if photo.analysis.status == .successful {
                            photo = PhotoIdentity(id: photo.id, relativePath: photo.relativePath, dateAdded: photo.dateAdded,
                                contentVersion: try CatalogCounters.successor(photo.contentVersion, minimum: 1))
                        }
                        if let bytes = readBytes {
                            // Detection failure does not discard an independently valid bounded preview.
                            try checkStop()
                            try await repository.requireLease(generation)
                            let preview: Data?
                            do { preview = try JPEGPreviewDecoder.jpeg(JPEGPreviewDecoder.decode(bytes)) }
                            catch let error as ScanError where error == .malformed || error == .oversized { preview = nil }
                            if let preview {
                                try checkStop()
                                try await repository.checkStorage()
                                let previewPath = try await repository.storePreview(preview, id: photo.id,
                                    generation: "\(photo.contentVersion)-\(generation)", lease: generation)
                                try checkStop()
                                try await repository.requireLease(generation)
                                photo.previewPath = previewPath
                                photo.captureDate = CaptureDateMetadata.extract(fromValidatedJPEG: bytes)
                            }
                        }
                        photo.analysis = FaceAnalysisState(status: .failed, contentVersion: photo.contentVersion, reason: "Photo analysis failed.")
                        progress.failed += 1
                    }
                }
                try await repository.save(photo, progress: pinnedCheckpoint ?? progress, lease: generation)
                await publish(progress, photo)
                // Only this iteration's verified bytes qualify: an ordinary read or the single
                // admitted catch-up read. The trusted no-read path never enriches.
                if let enrichment, let bytes = readBytes, let hash = readHash,
                   photo.analysis.status == .successful, photo.contentHash == hash {
                    try await enrich(enrichment, ScanEnrichmentRequest(photo: photo, entry: entry,
                        sourceIdentity: identity, bytes: bytes, contentHash: hash), progress: &progress)
                }
                progress.phase = .discovering
            }
            try checkStop()
            progress.enumerationFinished = true; progress.phase = .completed
            if let remaining, !remaining.isEmpty {
                progress.failed += remaining.count
                progress.message = "Some listed photos were not found in the source folder."
            } else if targets != nil {
                progress.message = "Face analysis finished for the listed photos."
            } else if previewsUnavailable > 0 {
                progress.message = previewsUnavailable == 1
                    ? "Source integrity verified. One cached preview remains unavailable; accepted analysis is unchanged."
                    : "Source integrity verified. \(previewsUnavailable) cached previews remain unavailable; accepted analyses are unchanged."
            } else {
                progress.message = "Source integrity verified. Counts describe this completed discovery pass."
            }
            if targets == nil {
                for photo in try await repository.markMissing(except: seen, progress: progress, lease: generation) {
                    await publish(progress, photo)
                }
            }
        } catch let error as CounterError {
            progress.phase = .failed
            progress.message = error == .exhausted
                ? "Catalog limit reached. Accepted photos remain in the catalog."
                : "Catalog counters could not be read safely. Accepted photos remain in the catalog."
            if let lease, targets == nil || pinnedCheckpoint != nil { try? await repository.save(progress: pinnedCheckpoint ?? progress, lease: lease) }
        } catch is CancellationError {
            progress.phase = .cancelled
            if previewRecoveryPending {
                progress.message = "Scan cancelled. Accepted analysis remains; preview recovery will retry when resumed."
            } else {
                progress.message = "Scan cancelled. Accepted photos remain; resume to check the source."
            }
            if let lease, targets == nil || pinnedCheckpoint != nil { try? await repository.save(progress: pinnedCheckpoint ?? progress, lease: lease) }
        } catch let error as ScanError {
            progress.phase = (error == .paused || error == .storagePressure) ? .paused : .failed
            if previewRecoveryPending {
                progress.message = "Preview unavailable. Accepted analysis remains; resume after source or storage access is available."
            } else {
                progress.message = error.message
            }
            if let lease, targets == nil || pinnedCheckpoint != nil { try? await repository.save(progress: pinnedCheckpoint ?? progress, lease: lease) }
        } catch {
            progress.phase = .failed
            progress.message = previewRecoveryPending
                ? "Preview unavailable. Accepted analysis remains; recovery can be retried when access is available."
                : "Scan failed. Accepted photos remain in the catalog."
            if let lease, targets == nil || pinnedCheckpoint != nil { try? await repository.save(progress: pinnedCheckpoint ?? progress, lease: lease) }
        }
        await source.close(); await publish(progress, nil)
        return progress
    }
    /// One admitted catch-up read of a trusted unchanged photo whose durable analysis is missing
    /// or source-stale. The verified bytes flow through the same enrichment dispatch as an
    /// ordinary read; a hash mismatch discards them and keeps the accepted analysis.
    private func admittedRead(_ enrichment: any ScanEnrichment, source: any PhotoSource,
                               entry: SourceEntry, photo: PhotoIdentity, generation: Int,
                               progress: inout ScanProgress) async throws -> (bytes: Data, hash: String)? {
        try checkStop()
        try await repository.requireLease(generation)
        progress.message = "Checking saved face details and on-device model readiness."
        await publish(progress, nil)
        guard await enrichment.needsAdmittedRead(photo) else { return nil }
        try checkStop()
        try await repository.requireLease(generation)
        progress.message = "Reading one unchanged photo to complete saved face details."
        await publish(progress, nil)
        let bytes = try await source.read(entry)
        let hash = try digest(bytes)
        guard hash == photo.contentHash else { return nil }
        progress.message = "Completing saved face details from the verified unchanged photo."
        await publish(progress, nil)
        return (bytes, hash)
    }

    /// Awaits enrichment to its actual return; cancellation propagates only after that drain.
    /// Stage messages are published, never checkpointed, and ordinary failure is reported only.
    private func enrich(_ enrichment: any ScanEnrichment, _ request: ScanEnrichmentRequest,
                        progress: inout ScanProgress) async throws {
        try checkStop()
        let base = progress
        do {
            try await enrichment.enrich(request) { [weak self] message in
                var update = base; update.message = message
                await self?.publishStage(update)
            }
            try checkStop()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try checkStop()
            progress.message = "Face details unavailable for this photo. Accepted analysis is unchanged."
            await publish(progress, nil)
        }
    }
    /// Stage text never overwrites a cancelling or paused surface.
    private func publishStage(_ progress: ScanProgress) async {
        guard !cancelled, !paused, !Task.isCancelled else { return }
        await publish(progress, nil)
    }
    private func publish(_ progress: ScanProgress, _ photo: PhotoIdentity?) async {
        current = progress
        await observer?(progress, photo)
    }
    private func digest(_ data: Data) throws -> String {
        var hash = SHA256()
        for start in stride(from: 0, to: data.count, by: 65536) {
            try checkStop()
            hash.update(data: data.subdata(in: start..<min(start + 65536, data.count)))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private func checkStop() throws {
        if cancelled || Task.isCancelled { throw CancellationError() }
        if paused { throw ScanError.paused }
    }
}
