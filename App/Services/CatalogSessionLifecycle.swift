import Foundation
import AFITCCore
import UIKit

/// Tracks actual work through completion; cancellation alone never establishes drain.
@MainActor
final class CatalogSessionLifecycle {
    struct Operation: Hashable {
        let id: UUID
        let session: UInt64
        let kind: String
    }
    private struct Pending {
        let operation: Operation
        var cancel: () -> Void
    }
    private(set) var session: UInt64 = 1
    private(set) var quiescing = false
    private(set) var timedOut = false
    private var drainSucceeded = false
    private var pending: [UUID: Pending] = [:]
    private var waiter: CheckedContinuation<Bool, Never>?
    private var deadline: Task<Void, Never>?
    var changed: (() -> Void)?
    var activeCount: Int { pending.count }
    var activeKinds: [String] { pending.values.map(\.operation.kind).sorted() }
    func isCurrent(_ session: UInt64) -> Bool { self.session == session && !quiescing }
    func begin(_ kind: String) -> Operation? {
        guard !quiescing else { return nil }
        let operation = Operation(id: UUID(), session: session, kind: kind)
        pending[operation.id] = Pending(operation: operation, cancel: {})
        changed?()
        return operation
    }
    func bind(_ operation: Operation, cancel: @escaping () -> Void) {
        guard var entry = pending[operation.id] else { return }
        entry.cancel = cancel; pending[operation.id] = entry
        if quiescing { cancel() }
    }
    func finish(_ operation: Operation) {
        pending.removeValue(forKey: operation.id)
        changed?()
        if pending.isEmpty, quiescing, waiter != nil { resolve(true) }
    }
    /// Synchronous fence; real workers remain registered until their completion.
    @discardableResult func closeAdmission() -> Bool {
        if !quiescing {
            guard session < UInt64.max else { return false }
            quiescing = true; session += 1; drainSucceeded = false
        }
        changed?()
        for cancel in pending.values.map(\.cancel) { cancel() }
        return true
    }
    /// Explicit retries re-drain the same closed epoch; late completion alone is insufficient.
    func quiesce(seconds: Double = 15) async -> Bool {
        guard seconds > 0, seconds.isFinite, waiter == nil else { return false }
        guard closeAdmission() else { return false }
        // Only a new explicit drain attempt may clear a previous timeout.
        timedOut = false; drainSucceeded = false
        changed?()
        let cancellations = pending.values.map(\.cancel)
        for cancel in cancellations { cancel() }
        if pending.isEmpty {
            drainSucceeded = true; changed?()
            return true
        }
        return await withCheckedContinuation { continuation in
            waiter = continuation
            deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(seconds)) }
                catch { return }
                self?.resolve(false)
            }
        }
    }
    private func resolve(_ drained: Bool) {
        guard let continuation = waiter else { return }
        timedOut = !drained; drainSucceeded = drained
        deadline?.cancel(); deadline = nil; waiter = nil
        changed?()
        continuation.resume(returning: drained)
    }
    /// The caller publishes its complete fresh graph synchronously before reopening admission.
    func adopt(_ publish: () -> Void) -> Bool {
        guard quiescing, pending.isEmpty, waiter == nil, !timedOut, drainSucceeded else { return false }
        publish()
        quiescing = false; drainSucceeded = false; changed?()
        return true
    }
    #if DEBUG
    private var held: Set<UUID> = []
    private var holdWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// Causal gate after a real repository read; cancellation cannot pretend the worker ended.
    func hold(_ operation: Operation) async {
        held.insert(operation.id); changed?()
        await withCheckedContinuation { holdWaiters[operation.id] = $0 }
        held.remove(operation.id); changed?()
    }
    func releaseHeld() {
        let waiting = Array(holdWaiters.values); holdWaiters.removeAll()
        for continuation in waiting { continuation.resume() }
    }
    var heldCount: Int { held.count }
    #endif
}

#if DEBUG
/// Explicit generated fixture only; shared with the real scan path.
actor AppSessionSyntheticDetector: DetectionProvider {
    func process(_ data: Data, contentVersion: Int) async throws -> ProcessedPreview {
        try Task.checkCancellation()
        let image = try JPEGPreviewDecoder.decode(data)
        return ProcessedPreview(jpeg: try JPEGPreviewDecoder.jpeg(image), analysis: FaceAnalysisState(
            status: .successful, detectorVersion: "synthetic-ui-preview-only-v1", contentVersion: contentVersion,
            faces: ProcessInfo.processInfo.arguments.contains("--uitest-synthetic-faces")
                ? [FaceGeometry(rectangle: [0.05, 0.1, 0.3, 0.7], landmarks: []),
                   FaceGeometry(rectangle: [0.6, 0.2, 0.3, 0.6], landmarks: [])] : []))
    }
}
actor AppSessionSlowSyntheticSource: PhotoSource {
    let source: FolderPhotoSource
    var returned = 0
    let holdAfterFirst: Bool
    init(source: FolderPhotoSource, holdAfterFirst: Bool) { self.source = source; self.holdAfterFirst = holdAfterFirst }
    func identity() async throws -> String? { try await source.identity() }
    func permissionBookmark() async throws -> Data? { try await source.permissionBookmark() }
    func open() async throws { try await source.open() }
    func next() async throws -> SourceEntry? {
        if returned > 0, holdAfterFirst {
            while true { try await Task.sleep(nanoseconds: 100_000_000) }
        }
        returned += 1
        return try await source.next()
    }
    func read(_ entry: SourceEntry) async throws -> Data { try await source.read(entry) }
    func close() async { await source.close() }
}
#endif

extension AppServices {
    public var isScanning: Bool { [.discovering, .processing, .cancelling].contains(progress.phase) }
    func sessionIsCurrent(_ session: UInt64) -> Bool { catalogSession.isCurrent(session) }
    #if DEBUG
    func releaseHeldSessionWork() { catalogSession.releaseHeld() }
    func holdSessionWork(_ operation: CatalogSessionLifecycle.Operation) async {
        guard usesSyntheticFixture, ProcessInfo.processInfo.arguments.contains("--uitest-session-hold-" + operation.kind) else { return }
        await catalogSession.hold(operation)
    }
    #endif
}

#if DEBUG
enum AppSessionFixture {
    static func root() throws -> URL {
                    let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("AFITCFixture-" + UUID().uuidString, isDirectory: true)
                    let nested = root.appendingPathComponent("nested", isDirectory: true)
                    try CatalogRepository.protect(nested, directory: true)
                    let context = CGContext(data: nil, width: 32, height: 16, bitsPerComponent: 8,
                        bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
                    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
                    context.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
                    let data = try JPEGPreviewDecoder.jpeg(context.makeImage()!)
                    for index in 0..<3 { try data.write(to: nested.appendingPathComponent("synthetic-\(index).jpg")) }
                    return root
    }
}
#endif
