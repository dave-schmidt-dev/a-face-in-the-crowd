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
    public func scan(source: any PhotoSource, detector: any DetectionProvider, confirmedSource: Bool = false,
                     update: @escaping @Sendable (ScanProgress, PhotoIdentity?) async -> Void) async -> ScanProgress {
        var progress = ScanProgress()
        guard !running else { progress.phase = .failed; progress.message = "A scan is already running."; return progress }
        running = true; cancelled = false; paused = false; observer = update
        defer { running = false; observer = nil }
        var lease: Int?
        do {
            let cached = try await repository.photos()
            progress.phase = .discovering
            progress.message = "Opening source. Showing last verified catalog before integrity checks."
            await publish(progress, nil)
            for photo in cached { try checkStop(); await publish(progress, photo) }
            try checkStop()
            try await source.open()
            let identity = try await source.identity()
            lease = try await repository.acquireSource(identity: identity, confirmed: confirmedSource)
            let generation = lease!
            if let bookmark = try await source.permissionBookmark() {
                try await repository.storeGrant(bookmark, lease: generation)
            }
            progress.phase = .discovering
            try await repository.save(progress: progress, lease: generation)
            await publish(progress, nil)
            let existing = Dictionary(uniqueKeysWithValues: cached.map { ($0.relativePath, $0) })
            var seen = Set<String>()
            while true {
                try checkStop()
                try await repository.requireLease(generation)
                guard let entry = try await source.next() else { break }
                guard seen.insert(entry.relativePath).inserted else { continue }
                progress.discovered += 1; progress.phase = .processing
                progress.message = "Checking source integrity. Cached previews show the last verified content."
                await publish(progress, nil)
                var photo = existing[entry.relativePath] ?? PhotoIdentity(relativePath: entry.relativePath)
                await publish(progress, photo)
                var readBytes: Data?
                do {
                    try await repository.checkStorage()
                    let trustworthy = entry.metadata?.revision != nil && entry.metadata?.revision == photo.metadata?.revision
                    if trustworthy, photo.analysis.status == .successful, photo.contentHash != nil {
                        photo.missing = false; photo.verifiedAt = Date()
                    } else {
                        let bytes = try await source.read(entry)
                        readBytes = bytes
                        let hash = try digest(bytes)
                        try checkStop()
                        if hash != photo.contentHash || photo.analysis.status != .successful {
                            if photo.contentHash != nil && hash != photo.contentHash {
                                // Old face UUIDs and their decisions remain tied to the old generation.
                                photo = PhotoIdentity(id: photo.id, relativePath: photo.relativePath, dateAdded: photo.dateAdded,
                                    contentVersion: photo.contentVersion + 1)
                            }
                            photo.contentHash = hash; photo.metadata = entry.metadata; photo.missing = false
                            photo.analysis = FaceAnalysisState(status: .pending, contentVersion: photo.contentVersion)
                            // Invalidation is durable before processing; interruption cannot resurrect old faces.
                            try await repository.save(photo, progress: progress, lease: generation)
                            await publish(progress, photo)
                            progress.message = "Preparing preview and detecting faces."
                            await publish(progress, nil)
                            let result = try await detector.process(bytes, contentVersion: photo.contentVersion)
                            try checkStop()
                            try await repository.requireLease(generation)
                            guard result.analysis.contentVersion == photo.contentVersion else { throw ScanError.staleLease }
                            photo.previewPath = try await repository.storePreview(result.jpeg, id: photo.id,
                                generation: "\(photo.contentVersion)-\(generation)", lease: generation)
                            photo.analysis = result.analysis
                        }
                        // Processing validated these bytes, or their exact hash identifies the prior validated generation.
                        // Weak metadata reads can backfill legacy records; trusted no-read reuse preserves nil too.
                        photo.captureDate = CaptureDateMetadata.extract(fromValidatedJPEG: bytes)
                        photo.metadata = entry.metadata; photo.contentHash = hash
                        photo.missing = false; photo.verifiedAt = Date()
                    }
                    progress.processed += 1
                } catch let error as ScanError where error == .malformed || error == .oversized || error == .unsafePath {
                    // Unreadable changed bytes must not retain an old confirmed face index.
                    if photo.analysis.status == .successful {
                        photo = PhotoIdentity(id: photo.id, relativePath: photo.relativePath, dateAdded: photo.dateAdded,
                            contentVersion: photo.contentVersion + 1)
                    }
                    photo.captureDate = nil
                    photo.analysis = FaceAnalysisState(status: .skipped, contentVersion: photo.contentVersion, reason: error.message)
                    progress.skipped += 1
                } catch let error as ScanError where error == .paused || error == .storagePressure || error == .unavailable || error == .denied || error == .staleLease {
                    throw error
                } catch is CancellationError { throw CancellationError() }
                catch {
                    if photo.analysis.status == .successful {
                        photo = PhotoIdentity(id: photo.id, relativePath: photo.relativePath, dateAdded: photo.dateAdded,
                            contentVersion: photo.contentVersion + 1)
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
                            photo.previewPath = try await repository.storePreview(preview, id: photo.id,
                                generation: "\(photo.contentVersion)-\(generation)", lease: generation)
                            photo.captureDate = CaptureDateMetadata.extract(fromValidatedJPEG: bytes)
                        }
                    }
                    photo.analysis = FaceAnalysisState(status: .failed, contentVersion: photo.contentVersion, reason: "Photo analysis failed.")
                    progress.failed += 1
                }
                try await repository.save(photo, progress: progress, lease: generation)
                await publish(progress, photo)
                progress.phase = .discovering
            }
            try checkStop()
            progress.enumerationFinished = true; progress.phase = .completed
            progress.message = "Source integrity verified. Counts describe this completed discovery pass."
            for photo in try await repository.markMissing(except: seen, progress: progress, lease: generation) {
                await publish(progress, photo)
            }
        } catch is CancellationError {
            progress.phase = .cancelled; progress.message = "Scan cancelled. Accepted photos remain; resume to check the source."
            if let lease { try? await repository.save(progress: progress, lease: lease) }
        } catch let error as ScanError {
            progress.phase = (error == .paused || error == .storagePressure) ? .paused : .failed
            progress.message = error.message
            if let lease { try? await repository.save(progress: progress, lease: lease) }
        } catch {
            progress.phase = .failed; progress.message = "Scan failed. Accepted photos remain in the catalog."
            if let lease { try? await repository.save(progress: progress, lease: lease) }
        }
        await source.close(); await publish(progress, nil)
        return progress
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
