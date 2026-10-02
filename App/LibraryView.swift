import SwiftUI
import UniformTypeIdentifiers
import AFITCCore

struct LibraryView: View {
    @ObservedObject var services: AppServices
    let surface: Color
    let secondary: Color
    let primary: Color
    let onPrimary: Color
    @State private var picker = false
    @State private var confirmation = false
    @State private var reconnectConfirmation = false
    @State private var selectionError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("A Face in the Crowd").font(.largeTitle.bold())
            Text("Find the people in your photo collection.").font(.title3)
            if services.canStart && !services.isScanning {
                VStack(alignment: .leading, spacing: 16) {
                    Label("Start with a photo folder", systemImage: "folder").font(.headline)
                    Text("Choose one folder to browse JPEGs, including nested folders. Your originals stay unchanged.")
                        .foregroundStyle(secondary)
                    Button {
                        if services.usesSyntheticFixture { services.chooseSyntheticFixture() }
                        else { picker = true }
                    } label: {
                        Text("Choose a photo folder").font(.headline).frame(minHeight: 44)
                            .padding(.horizontal, 16).foregroundStyle(onPrimary).background(primary)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }.accessibilityIdentifier("choose-folder")
                    if services.selectedFolder != nil {
                        Button("Start scan") { confirmation = true }.frame(minHeight: 44)
                            .accessibilityIdentifier("start-scan")
                    }
                    if let selectionError { Text(selectionError) }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                    .background(surface).clipShape(RoundedRectangle(cornerRadius: 16))
            } else if services.isOpeningCatalog {
                ProgressView("Opening catalog")
            }
            if !services.photos.isEmpty {
                Text("Last verified photos").font(.headline)
                Text("Detected faces need your confirmation. Detection may miss people; zero detected faces is not an identity claim.")
                    .foregroundStyle(secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220))], spacing: 16) {
                    ForEach(services.photos) { photo in
                        VStack(alignment: .leading, spacing: 8) {
                            PhotoPreview(url: services.previewURL(photo), pending: photo.analysis.status == .pending)
                            Text(photo.relativePath).lineLimit(2)
                            if photo.missing == true { Text("Missing at last complete discovery").font(.caption) }
                            Text("Detection: \(photo.analysis.status.rawValue) · \(photo.analysis.faces.count) faces")
                                .font(.subheadline)
                            if let reason = photo.analysis.reason { Text(reason).font(.caption) }
                        }.padding(16).background(surface).clipShape(RoundedRectangle(cornerRadius: 12))
                            .accessibilityIdentifier("photo-\(photo.id.uuidString)")
                    }
                }
            }
        }
        .fileImporter(isPresented: $picker, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { services.choose(url); selectionError = nil }
            case .failure: selectionError = "Folder access was cancelled or denied."
            }
        }
        .onChange(of: services.progress.message) { _, message in
            if message == ScanError.sourceConfirmationRequired.message {
                reconnectConfirmation = true; confirmation = true
            }
        }
        .alert(reconnectConfirmation ? "Confirm the original source" : "Scan this folder?", isPresented: $confirmation) {
            Button(reconnectConfirmation ? "This is the original folder" : "Start scan") {
                services.startScan(confirmedSource: reconnectConfirmation)
                reconnectConfirmation = false
            }
            Button("Cancel", role: .cancel) { reconnectConfirmation = false }
        } message: {
            Text(reconnectConfirmation
                ? "The provider could not verify this folder's identity. Confirm only if this is the original drive and root folder. A same-named different folder may replace indexed content."
                : "JPEG previews and face detection stay on this iPad. Originals remain unchanged. Existing previews remain available while source integrity is checked.")
        }
    }
}

/// Reading/decompressing derived JPEGs also stays off the UI executor.
private struct PhotoPreview: View {
    let url: URL?
    let pending: Bool
    @State private var image: UIImage?
    @State private var loading = true
    @State private var decodeToken = UUID()
    @State private var releasedForMemory = false
    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 200)
                    .accessibilityLabel("Photo preview")
            } else if pending || loading {
                ProgressView("Preparing preview")
            } else {
                Label(releasedForMemory ? "Preview released to free memory" :
                    (url == nil ? "Preview not generated" : "Preview unavailable offline"), systemImage: "photo")
            }
        }
        .frame(height: 200)
        .onDisappear { releaseDecodedPreview() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            releaseDecodedPreview(forMemory: true)
        }
        .task(id: url) {
            let token = UUID()
            decodeToken = token; image = nil; loading = true; releasedForMemory = false
            let decoded: UIImage?
            if let url {
                decoded = await Task.detached(priority: .utility) { UIImage(contentsOfFile: url.path) }.value
            } else { decoded = nil }
            // Detached decode may finish after SwiftUI cancels its parent task.
            guard !Task.isCancelled, decodeToken == token else { return }
            image = decoded; loading = false
        }
    }
    private func releaseDecodedPreview(forMemory: Bool = false) {
        guard image != nil || loading else { return }
        decodeToken = UUID()
        image = nil; loading = false; releasedForMemory = forMemory
    }
}
