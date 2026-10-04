import SwiftUI
import UIKit
import CryptoKit
import AFITCCore

@MainActor
private final class ViewerController: ObservableObject {
    @Published var image: UIImage?
    @Published var status = "Opening photo"
    private var token = UUID()
    private var worker: Task<CGImage, Error>?
    private var request: Task<Void, Never>?
    #if DEBUG
    private weak var probeServices: AppServices?
    private var probeSession: UInt64?
    #endif
    func release() {
        #if DEBUG
        if let probeSession, probeServices?.sessionIsCurrent(probeSession) == true {
            probeServices?.releaseViewerProbe(token)
        }
        #endif
        token = UUID(); request?.cancel(); worker?.cancel(); request = nil; worker = nil
        image = nil; status = "Image released. Reopen to load it again."
    }
    func load(photo: PhotoIdentity, services: AppServices) {
        release()
        guard let operation = services.catalogSession.begin("viewer") else { return }
        status = "Opening photo"
        let current = token, generation = services.viewerSourceGeneration
        let root = services.selectedFolder, cache = services.previewURL(photo), synthetic = services.usesSyntheticFixture
        #if DEBUG
        probeServices = services; probeSession = operation.session; services.beginViewerProbe(current)
        #endif
        let job = Task {
            defer { services.catalogSession.finish(operation) }
            #if DEBUG
            defer { if services.sessionIsCurrent(operation.session) { services.finishViewerProbe(current) } }
            #endif
            var original = false
            do {
                guard let root else { throw ScanError.unavailable }
                #if DEBUG
                if synthetic && ProcessInfo.processInfo.arguments.contains("--uitest-viewer-disconnect") { throw ScanError.unavailable }
                if synthetic && ProcessInfo.processInfo.arguments.contains("--uitest-viewer-hold-read") {
                    try await Task.sleep(for: .seconds(10))
                }
                #endif
                #if DEBUG
                if synthetic {
                    let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                    // Faults touch only this run's explicitly generated app-container fixture.
                    if root.deletingLastPathComponent().standardizedFileURL == cacheRoot.standardizedFileURL,
                       root.lastPathComponent.hasPrefix("AFITCFixture-") {
                        if ProcessInfo.processInfo.arguments.contains("--uitest-viewer-change-bytes") {
                            let original = root.appendingPathComponent(photo.relativePath)
                            let bytes = try Data(contentsOf: original)
                            var changed = bytes; changed.append(0) // Valid JPEG with a different exact byte hash.
                            try changed.write(to: original)
                        }
                    }
                }
                #endif
                let source: FolderSource
                #if DEBUG
                source = synthetic ? FolderSource.syntheticFixture(root: root) : FolderSource(root: root)
                #else
                source = FolderSource(root: root)
                #endif
                do {
                    try await source.open()
                    try Task.checkCancellation()
                    guard services.sessionIsCurrent(operation.session) else { await source.close(); return }
                    let identity = try await source.identity()
                    try await services.validateViewerPhoto(photo, sourceIdentity: identity, session: operation.session)
                    let bytes = try await source.read(SourceEntry(relativePath: photo.relativePath))
                    try Task.checkCancellation()
                    let work = Task.detached {
                        try Task.checkCancellation()
                        guard bytes.count <= DecodeLimits.maximumFileBytes else { throw ScanError.oversized }
                        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                        return (try PreviewService.decode(bytes), digest)
                    }
                    let decoded = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                    try await services.validateViewerPhoto(photo, sourceIdentity: try await source.identity(), hash: decoded.1, session: operation.session)
                    await source.close()
                    #if DEBUG
                    await services.holdSessionWork(operation)
                    #endif
                    guard services.sessionIsCurrent(operation.session) else { return }
                    #if DEBUG
                    if synthetic && ProcessInfo.processInfo.arguments.contains("--uitest-viewer-memory-warning") {
                        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
                    }
                    #endif
                    try Task.checkCancellation()
                    guard services.sessionIsCurrent(operation.session), token == current, services.viewerSourceGeneration == generation,
                          services.selectedFolder == root else { return }
                    #if DEBUG
                    services.publicationViewerProbe(current)
                    #endif
                    image = UIImage(cgImage: decoded.0); original = true
                } catch { await source.close(); throw error }
            } catch is CancellationError {
                #if DEBUG
                if services.sessionIsCurrent(operation.session) { services.cancelViewerProbe(current) }
                #endif
                return
            }
            catch {
                guard services.sessionIsCurrent(operation.session), token == current, services.viewerSourceGeneration == generation else { return }
                do {
                    guard let cache else { throw ScanError.unavailable }
                    #if DEBUG
                    if synthetic && ProcessInfo.processInfo.arguments.contains("--uitest-viewer-evict-preview") {
                        try? FileManager.default.removeItem(at: cache)
                    }
                    #endif
                    let work = Task.detached {
                        try Task.checkCancellation()
                        let handle = try FileHandle(forReadingFrom: cache)
                        defer { try? handle.close() }
                        let bytes = try handle.read(upToCount: DecodeLimits.maximumFileBytes + 1) ?? Data()
                        #if DEBUG
                        if synthetic && ProcessInfo.processInfo.arguments.contains("--uitest-viewer-fallback-error-after-release") {
                            // Causal race: release the raster/request before actual decoder failure returns.
                            await MainActor.run {
                                NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
                            }
                            // The injected decoder fault deliberately remains non-cancellation after release.
                            try? await Task.sleep(for: .milliseconds(100))
                            return try PreviewService.decode(Data(bytes.prefix(2)))
                        }
                        #endif
                        return try PreviewService.decode(bytes)
                    }
                    worker = work
                    let decoded = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                    try Task.checkCancellation()
                    guard services.sessionIsCurrent(operation.session), token == current, services.viewerSourceGeneration == generation else { return }
                    #if DEBUG
                    services.publicationViewerProbe(current)
                    #endif
                    image = UIImage(cgImage: decoded)
                } catch is CancellationError {
                    #if DEBUG
                    if services.sessionIsCurrent(operation.session) { services.cancelViewerProbe(current) }
                    #endif
                    return
                } catch {
                    guard services.sessionIsCurrent(operation.session), token == current, services.viewerSourceGeneration == generation else { return }
                    status = "Preview unavailable. Connect the selected source and refresh search."
                }
            }
            guard services.sessionIsCurrent(operation.session), token == current, services.viewerSourceGeneration == generation else { return }
            if image != nil { status = original ? "Original · up to 1024px" : "Preview only · original unavailable or changed" }
            request = nil; worker = nil
        }
        request = job
        services.catalogSession.bind(operation) { [weak self] in job.cancel(); self?.release() }
    }
}

struct PhotoViewer: View {
    let photo: PhotoIdentity
    @ObservedObject var services: AppServices
    @StateObject private var controller = ViewerController()
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Group {
                        if let image = controller.image {
                            Image(uiImage: image).resizable().scaledToFit().accessibilityLabel("Photo view")
                                .accessibilityIdentifier("viewer-image")
                        } else if controller.status == "Opening photo" {
                            ProgressView("Opening photo")
                        } else { Text(controller.status).multilineTextAlignment(.center) }
                    }.frame(maxWidth: .infinity).frame(height: 360)
                    Text(controller.status).accessibilityIdentifier("viewer-status")
                    #if DEBUG
                    if services.usesSyntheticFixture, ProcessInfo.processInfo.arguments.contains("--uitest-viewer-fallback-error-after-release") {
                        Text(services.syntheticViewerProbe).font(.caption).accessibilityIdentifier("viewer-request-detail-probe")
                    }
                    #endif
                    #if DEBUG
                    if services.usesSyntheticFixture, ProcessInfo.processInfo.arguments.contains("--uitest-session-controls") {
                        Text(services.sessionProbe).font(.caption).accessibilityIdentifier("viewer-session-probe")
                    }
                    #endif
                    Text(photo.relativePath).font(.caption).textSelection(.enabled)
                    if let date = photo.captureDate {
                        Text("Captured \(date.localWallClock)\(date.sourceOffset.map { " · source offset " + $0 } ?? "")")
                        Text("Source EXIF DateTimeOriginal").font(.caption)
                    } else { Text("Capture date unknown") }
                    Text("Read-only view. Originals stay unchanged.").font(.caption)
                }.padding(24)
            }
            .navigationTitle("Photo")
            .toolbar {
                Button("Done") { controller.release(); dismiss() }.frame(minHeight: 44).accessibilityIdentifier("close-viewer")
                #if DEBUG
                if services.usesSyntheticFixture, ProcessInfo.processInfo.arguments.contains("--uitest-session-controls") {
                    Button("Pause session") { Task { await services.quiesceCatalogSession() } }
                        .accessibilityIdentifier("quiesce-viewer-session")
                }
                #endif
            }
        }
        .task(id: "\(services.catalogSessionID):\(services.viewerSourceGeneration):\(services.selectedFolder?.absoluteString ?? "")") { controller.load(photo: photo, services: services) }
        .onDisappear { controller.release() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in controller.release() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in controller.release() }
    }
}
