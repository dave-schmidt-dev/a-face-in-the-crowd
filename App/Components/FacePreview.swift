import SwiftUI
import AFITCCore

/// How a face preview is framed. Every style uses the same bounded cached-preview decode.
enum FacePreviewStyle: Equatable {
    /// Aspect-fit crop (160 pt tall) or whole photo (360 pt tall), as before the design pass.
    case standard
    /// Circular portrait of the given diameter, used for people and unidentified faces.
    case circle(CGFloat)
    /// Square rounded tile that fills the available width, used in photo grids.
    case tile
}

/// All raster reads/crops use bounded orientation-normalized cached previews off the UI executor.
struct FacePreview: View {
    @ObservedObject var services: AppServices
    let face: FaceItem
    let wholePhoto: Bool
    var style: FacePreviewStyle = .standard
    @Environment(\.tokens) private var tokens
    @State private var image: UIImage?
    @State private var loading = true
    @State private var decodeToken = UUID()
    @State private var releasedForMemory = false
    private var decodeRequest: String {
        "\(face.key.id)|\(wholePhoto)|\(services.previewURL(face.photo)?.path ?? "")"
    }
    var body: some View {
        framed
            .onDisappear { releaseDecodedPreview() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                releaseDecodedPreview(forMemory: true)
            }
            .task(id: decodeRequest) { await decode() }
    }

    @ViewBuilder private var framed: some View {
        switch style {
        case .standard:
            content.frame(height: wholePhoto ? 360 : 160)
        case .circle(let diameter):
            ZStack { tokens.surfaceRaised; content }
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(tokens.border, lineWidth: 1))
        case .tile:
            ZStack { tokens.surfaceRaised; content }
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous))
        }
    }

    private var compact: Bool { style != .standard }

    @ViewBuilder private var content: some View {
        if let image {
            let label = wholePhoto ? "Whole photo context" : "Selected face crop"
            if compact {
                Color.clear.overlay(Image(uiImage: image).resizable().scaledToFill().accessibilityLabel(label)).clipped()
            } else {
                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: wholePhoto ? 360 : 160)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.control, style: .continuous))
                    .accessibilityLabel(label)
            }
        } else if loading {
            if compact { ProgressView().accessibilityLabel("Opening preview") } else { ProgressView("Opening preview") }
        } else if releasedForMemory {
            placeholder("Preview released to free memory")
                .accessibilityLabel("Preview released to free memory")
                .accessibilityIdentifier("face-preview-released")
        } else { placeholder("Preview unavailable offline") }
    }

    @ViewBuilder private func placeholder(_ text: String) -> some View {
        if compact {
            Image(systemName: "person.crop.circle").font(.title2).foregroundStyle(tokens.textSecondary)
                .accessibilityLabel(text)
        } else {
            Label(text, systemImage: "photo")
        }
    }

    private func decode() async {
        guard let operation = services.catalogSession.begin("face-preview") else { image = nil; loading = false; return }
        defer { services.catalogSession.finish(operation) }
        let token = UUID()
        decodeToken = token; image = nil; loading = true; releasedForMemory = false
        let url = services.previewURL(face.photo), rectangle = face.geometry.rectangle, whole = wholePhoto
        let work = Task.detached(priority: .utility) {
            guard let url, let full = UIImage(contentsOfFile: url.path), let raster = full.cgImage else { return nil as UIImage? }
            #if DEBUG
            await services.protection.holdPreview(operation)
            #endif
            if whole { return full }
            guard let crop = FaceCropGeometry.pixelRectangle(rectangle, width: raster.width, height: raster.height),
                  let cropped = raster.cropping(to: crop) else { return nil }
            return UIImage(cgImage: cropped)
        }
        services.catalogSession.bind(operation) { work.cancel() }
        let decoded = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        #if DEBUG
        // Causal runtime fixture: warn after a real decode but before its result can publish.
        // Normal DEBUG use and all release builds never select this hook.
        if decoded != nil, services.usesSyntheticFixture,
           services.launch.has("--uitest-face-preview-memory-warning") {
            NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        }
        #endif
        // Detached work can outlive SwiftUI's parent task or a memory-warning invalidation.
        guard services.sessionIsCurrent(operation.session), !Task.isCancelled, decodeToken == token else { return }
        image = decoded; loading = false
    }

    private func releaseDecodedPreview(forMemory: Bool = false) {
        guard image != nil || loading else { return }
        decodeToken = UUID()
        image = nil; loading = false; releasedForMemory = forMemory
    }
}
