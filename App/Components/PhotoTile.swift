import SwiftUI
import AFITCCore

/// Square rounded Library tile over the cached preview, with a small status badge only when
/// the photo needs attention (missing, detection pending/failed/skipped).
struct PhotoTile: View {
    @ObservedObject var services: AppServices
    let photo: PhotoIdentity
    /// Opens the read-only photo viewer. Tap and VoiceOver activation, without folding the
    /// preview image out of the accessibility tree.
    var onOpen: (() -> Void)?
    @Environment(\.tokens) private var tokens

    var body: some View {
        PhotoPreview(services: services, url: services.previewURL(photo), pending: photo.analysis.status == .pending)
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .background(tokens.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous))
            .overlay(alignment: .bottomLeading) { badge.padding(DesignTokens.Spacing.xs) }
            .contentShape(Rectangle())
            .onTapGesture { onOpen?() }
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(onOpen == nil ? [] : .isButton)
            .accessibilityAction(named: "Open photo") { onOpen?() }
    }

    @ViewBuilder private var badge: some View {
        if photo.missing == true {
            status("Missing at last complete discovery", icon: "exclamationmark.triangle.fill", color: tokens.warning)
        } else if photo.analysis.status == .failed {
            status(photo.analysis.reason ?? "Detection failed", icon: "exclamationmark.circle.fill", color: tokens.destructive)
        } else if photo.analysis.status == .skipped {
            status(photo.analysis.reason ?? "Detection skipped", icon: "minus.circle.fill", color: tokens.controlBoundary)
        }
    }

    /// Opaque backing keeps badge text readable over any photo.
    private func status(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon).labelStyle(.titleAndIcon).font(.caption2.weight(.semibold)).lineLimit(2)
            .padding(.horizontal, DesignTokens.Spacing.xs).padding(.vertical, DesignTokens.Spacing.xxs)
            .foregroundStyle(tokens.textPrimary)
            .background(tokens.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(color, lineWidth: 1.5))
    }
}

/// Reading/decompressing derived JPEGs also stays off the UI executor.
struct PhotoPreview: View {
    @ObservedObject var services: AppServices
    let url: URL?
    let pending: Bool
    @Environment(\.tokens) private var tokens
    @State private var image: UIImage?
    @State private var loading = true
    @State private var decodeToken = UUID()
    @State private var releasedForMemory = false
    var body: some View {
        Group {
            if let image {
                Color.clear.overlay(Image(uiImage: image).resizable().scaledToFill().accessibilityLabel("Photo preview")).clipped()
            } else if pending || loading {
                ProgressView("Preparing preview").font(.caption)
            } else {
                Label(releasedForMemory ? "Preview released to free memory" :
                    (url == nil ? "Preview not generated" : "Preview unavailable offline"), systemImage: "photo")
                    .font(.caption).foregroundStyle(tokens.textSecondary).padding(DesignTokens.Spacing.xs)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDisappear { releaseDecodedPreview() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            releaseDecodedPreview(forMemory: true)
        }
        .task(id: url) {
            guard let operation = services.catalogSession.begin("library-preview") else { image = nil; loading = false; return }
            defer { services.catalogSession.finish(operation) }
            let token = UUID()
            decodeToken = token; image = nil; loading = true; releasedForMemory = false
            let decoded: UIImage?
            if let url {
                let work = Task.detached(priority: .utility) {
                    let result = UIImage(contentsOfFile: url.path)
                    #if DEBUG
                    if result != nil { await services.protection.holdPreview(operation) }
                    #endif
                    return result
                }
                services.catalogSession.bind(operation) { work.cancel() }
                decoded = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            } else { decoded = nil }
            // Detached decode may finish after SwiftUI cancels its parent task.
            guard services.sessionIsCurrent(operation.session), !Task.isCancelled, decodeToken == token else { return }
            image = decoded; loading = false
        }
    }
    private func releaseDecodedPreview(forMemory: Bool = false) {
        guard image != nil || loading else { return }
        decodeToken = UUID()
        image = nil; loading = false; releasedForMemory = forMemory
    }
}
