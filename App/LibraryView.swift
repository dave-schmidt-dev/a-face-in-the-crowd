import SwiftUI
import UniformTypeIdentifiers
import AFITCCore

struct LibraryView: View {
    @ObservedObject var services: AppServices
    @Environment(\.tokens) private var tokens
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var picker = false
    @State private var confirmation = false
    @State private var reconnectConfirmation = false
    @State private var selectionError: String?
    @State private var viewer: PhotoIdentity?
    @State private var showsFaceNote = false
    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.l) {
            if services.photos.isEmpty {
                // Welcome / empty: brand, one explanation and one action, then the status.
                if services.canStart && !services.isScanning { welcome }
                else if services.isOpeningCatalog { ProgressView("Opening catalog") }
                StatusView(services: services, showsDetails: true)
            } else {
                // Browsing: one compact status line, a slim action row, then the dense photo grid.
                StatusView(services: services, showsDetails: true)
                if services.canStart && !services.isScanning { actionRow }
                else if services.isOpeningCatalog { ProgressView("Opening catalog") }
                LazyVGrid(columns: columns, spacing: DesignTokens.Spacing.xxs) {
                    ForEach(services.photos) { photo in
                        PhotoTile(services: services, photo: photo) { viewer = photo }
                            .presentationAnchor(photo.id, section: "Library")
                            .accessibilityIdentifier("photo-\(photo.id.uuidString)")
                    }
                }
                footer
            }
        }
        .sheet(item: $viewer) { PhotoViewer(photo: $0, services: services) }
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

    private var welcome: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.m) {
            BrandLockup().padding(.bottom, DesignTokens.Spacing.xs)
            Text("Put a name to the memories.").font(.title3.weight(.semibold))
            Text("Your photos stay on your drive. Names and previews stay on this iPad. Choose one folder to browse JPEGs, including nested folders; originals are never changed.")
                .foregroundStyle(tokens.textSecondary)
            sourceRow
            if let selectionError { Text(selectionError).foregroundStyle(tokens.destructive) }
        }.card(padding: DesignTokens.Spacing.l)
    }

    private var actionRow: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            sourceRow
            if let selectionError { Text(selectionError).foregroundStyle(tokens.destructive) }
        }
    }

    private var sourceRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DesignTokens.Spacing.s) { sourceButtons }
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) { sourceButtons }
        }
    }

    /// "N photos · Folder" status line as in the approved Library mockup; the face-detection
    /// caveat sits one tap away instead of a standing paragraph.
    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.xs) {
            Text(summary).font(.subheadline.weight(.semibold)).foregroundStyle(tokens.textSecondary)
                .accessibilityIdentifier("library-summary")
            Button { showsFaceNote = true } label: {
                Image(systemName: "info.circle").frame(minWidth: DesignTokens.Layout.minimumHit, minHeight: DesignTokens.Layout.minimumHit)
            }
            .accessibilityLabel("About face detection")
            .accessibilityIdentifier("library-face-note")
            .popover(isPresented: $showsFaceNote) {
                Text("Detected faces need your confirmation. Detection may miss people; zero detected faces is not an identity claim.")
                    .padding(DesignTokens.Spacing.m).frame(minWidth: 260, maxWidth: 360)
                    .presentationCompactAdaptation(.popover)
            }
        }
    }

    @ViewBuilder private var sourceButtons: some View {
        Button {
            if services.usesSyntheticFixture { services.chooseSyntheticFixture() }
            else { picker = true }
        } label: {
            Label("Choose a photo folder", systemImage: "folder.badge.plus")
        }
        .buttonStyle(services.selectedFolder == nil ? CapsuleButtonStyle() : CapsuleButtonStyle(prominent: false))
        .accessibilityIdentifier("choose-folder")
        if services.selectedFolder != nil {
            Button { confirmation = true } label: { Label("Start scan", systemImage: "play.fill") }
                .buttonStyle(.capsule)
                .accessibilityIdentifier("start-scan")
        }
    }
    private var columns: [GridItem] {
        typeSize.isAccessibilitySize ? Array(repeating: GridItem(.flexible(), spacing: DesignTokens.Spacing.xxs), count: 2)
            : [GridItem(.adaptive(minimum: DesignTokens.Layout.photoGridMin), spacing: DesignTokens.Spacing.xxs)]
    }
    /// "N photos · Folder" status line, as in the approved Library mockup.
    private var summary: String {
        let count = services.photos.count == 1 ? "1 photo" : "\(services.photos.count) photos"
        guard let folder = services.selectedFolder?.lastPathComponent, !folder.isEmpty else { return count }
        return count + " · " + folder
    }
}
