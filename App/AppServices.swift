import Foundation
import UIKit
import AFITCCore

@MainActor
public final class AppServices: ObservableObject {
    public let databaseInfo: CatalogDatabaseInfo
    public let diagnostics: DiagnosticLog
    @Published public var photos: [PhotoIdentity] = []
    @Published public var progress = ScanProgress()
    @Published public var selectedFolder: URL?
    @Published public var setupError: String?
    @Published public var canStart = false
    @Published public var isOpeningCatalog = true
    @Published public var isRestoringSource = false
    private var sourceSelectionGeneration = 0
    #if DEBUG
    private var syntheticAttempts = 0
    #endif
    private var repository: CatalogRepository?
    private var coordinator: ScanCoordinator?
    private var scanTask: Task<Void, Never>?
    private var previewDirectory: URL?
    private var observers: [NSObjectProtocol] = []

    public init(databaseInfo: CatalogDatabaseInfo = CatalogDatabaseInfo()) {
        self.databaseInfo = databaseInfo
        let manager = FileManager.default
        #if DEBUG
        let isolated = ProcessInfo.processInfo.arguments.contains("--uitest-fresh-catalog") ||
            ProcessInfo.processInfo.arguments.contains("--uitest-synthetic-source")
        let container = isolated ? "AFITCTest-" + UUID().uuidString : "AFITC"
        #else
        let container = "AFITC"
        #endif
        let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(container, isDirectory: true)
        let cache = manager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(container, isDirectory: true)
        diagnostics = DiagnosticLog(directory: support.appendingPathComponent("Diagnostics", isDirectory: true),
                                    debugEnabled: ProcessInfo.processInfo.arguments.contains("--debug"))
        // Container preparation/SQLite migration are off the UI executor.
        Task {
            defer { isOpeningCatalog = false }
            do {
                let repo = try await Task.detached { try CatalogRepository(directory: support, cacheDirectory: cache) }.value
                repository = repo; coordinator = ScanCoordinator(repository: repo); previewDirectory = cache
                photos = try await repo.photos()
                if var saved = try await repo.checkpoint() {
                    if [.discovering, .processing, .cancelling].contains(saved.phase) {
                        saved.phase = .interrupted; saved.message = "Scan interrupted. Accepted previews remain; choose the source folder to resume."
                    }
                    progress = saved; canStart = true
                } else { canStart = true }
                isOpeningCatalog = false
                // Cached catalog/checkpoint is published before bookmark resolution or source IO.
                await restoreSourcePermission(from: repo)
                await diagnostics.record(.shellOpened, severity: .debug)
            } catch { setupError = "Catalog unavailable. Existing data has been preserved." }
        }
        for name in [UIApplication.didReceiveMemoryWarningNotification, UIApplication.protectedDataWillBecomeUnavailableNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.coordinator?.pause() }
            })
        }
    }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
    public var isScanning: Bool { [.discovering, .processing, .cancelling].contains(progress.phase) }
    private func restoreSourcePermission(from repo: CatalogRepository) async {
        isRestoringSource = true
        let selectionGeneration = sourceSelectionGeneration
        defer { isRestoringSource = false }
        await Task.yield()
        do {
            guard let grant = try await repo.loadGrant() else {
                if sourceSelectionGeneration == selectionGeneration, !photos.isEmpty {
                    setupError = "Choose the original source folder to resume."
                }
                return
            }
            let resolved = try await Task.detached(priority: .utility) { try CatalogRepository.resolveGrant(grant) }.value
            guard sourceSelectionGeneration == selectionGeneration else { return }
            selectedFolder = resolved.url
            if resolved.stale {
                setupError = "Source permission needs renewal. Start a scan to validate it, or choose the original folder again."
            }
        } catch {
            guard sourceSelectionGeneration == selectionGeneration else { return }
            setupError = "Saved source permission could not be restored. Choose the original folder again. Cached photos remain available."
        }
    }
    public func choose(_ url: URL) {
        sourceSelectionGeneration += 1; selectedFolder = url; setupError = nil
    }
    public func startScan(confirmedSource: Bool = false) {
        guard canStart, let selectedFolder, let coordinator, repository != nil else { return }
        canStart = false; setupError = nil
        progress.phase = .discovering
        scanTask = Task {
            let source: FolderSource
            #if DEBUG
            if usesSyntheticFixture { source = FolderSource.syntheticFixture(root: selectedFolder) }
            else { source = FolderSource(root: selectedFolder) }
            #else
            source = FolderSource(root: selectedFolder)
            #endif
            let scanSource: any PhotoSource
            #if DEBUG
            if usesSyntheticFixture {
                let hold = ProcessInfo.processInfo.arguments.contains("--uitest-hold-after-first") && syntheticAttempts == 0
                syntheticAttempts += 1
                scanSource = SlowSyntheticSource(source: source, holdAfterFirst: hold)
            } else { scanSource = source }
            #else
            scanSource = source
            #endif
            let detector: any DetectionProvider
            #if DEBUG
            if usesSyntheticFixture && ProcessInfo.processInfo.arguments.contains("--uitest-synthetic-detector") {
                detector = SyntheticUIDetector()
            } else { detector = FaceDetectionService() }
            #else
            detector = FaceDetectionService()
            #endif
            let result = await coordinator.scan(source: scanSource, detector: detector, confirmedSource: confirmedSource) { [weak self] progress, photo in
                await self?.receive(progress, photo)
            }
            progress = result
            canStart = true
        }
    }
    private func receive(_ value: ScanProgress, _ photo: PhotoIdentity?) {
        if !(progress.phase == .cancelling && [.processing, .discovering].contains(value.phase)) { progress = value }
        if let photo {
            if let index = photos.firstIndex(where: { $0.id == photo.id }) { photos[index] = photo }
            else { photos.append(photo) }
        }
    }
    public func cancelScan() {
        progress.phase = .cancelling
        progress.message = "Cancellation requested. Finishing the bounded current operation."
        scanTask?.cancel()
        Task { await coordinator?.cancel() }
    }
    public func previewURL(_ photo: PhotoIdentity) -> URL? {
        guard let name = photo.previewPath else { return nil }
        guard let previewDirectory else { return nil }
        let url = previewDirectory.appendingPathComponent(name)
        return url
    }
    var usesSyntheticFixture: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--uitest-synthetic-source")
        #else
        return false
        #endif
    }
    func chooseSyntheticFixture() {
        #if DEBUG
        guard usesSyntheticFixture else { return }
        Task {
            do {
                let root = try await Task.detached {
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
                }.value
                choose(root)
            } catch { setupError = "Synthetic fixture unavailable." }
        }
        #endif
    }
    #if DEBUG
    /// Explicit synthetic UI workflow evidence, never native Vision qualification.
    private actor SyntheticUIDetector: DetectionProvider {
        func process(_ data: Data, contentVersion: Int) async throws -> ProcessedPreview {
            try Task.checkCancellation()
            let image = try JPEGPreviewDecoder.decode(data)
            return ProcessedPreview(jpeg: try JPEGPreviewDecoder.jpeg(image), analysis: FaceAnalysisState(
                status: .successful, detectorVersion: "synthetic-ui-preview-only-v1", contentVersion: contentVersion))
        }
    }
    private actor SlowSyntheticSource: PhotoSource {
        let source: FolderPhotoSource
        var returned = 0
        let holdAfterFirst: Bool
        init(source: FolderPhotoSource, holdAfterFirst: Bool) { self.source = source; self.holdAfterFirst = holdAfterFirst }
        func identity() async throws -> String? { try await source.identity() }
        func permissionBookmark() async throws -> Data? { try await source.permissionBookmark() }
        func open() async throws { try await source.open() }
        func next() async throws -> SourceEntry? {
            if returned > 0, holdAfterFirst {
                // Deterministic DEBUG-only gate: XCTest cancellation releases this operation.
                while true { try await Task.sleep(nanoseconds: 100_000_000) }
            }
            returned += 1
            return try await source.next()
        }
        func read(_ entry: SourceEntry) async throws -> Data { try await source.read(entry) }
        func close() async { await source.close() }
    }
    #endif

}
