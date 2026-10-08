import SwiftUI
import UniformTypeIdentifiers
import AFITCCore

struct LibraryView: View {
    @ObservedObject var services: AppServices
    @Environment(\.tokens) private var tokens
    @Environment(\.dynamicTypeSize) private var typeSize
    var isActive = true
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
                if services.canStart && !services.isScanning {
                    welcome
                    if services.isScanning || services.isRestoringSource || services.setupError != nil
                        || services.progress.phase != .ready || services.selectedFolder != nil {
                        StatusView(services: services, showsDetails: true)
                    }
                } else {
                    if services.isOpeningCatalog { ProgressView("Opening catalog") }
                    StatusView(services: services, showsDetails: true)
                }
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
        .fullScreenCover(item: $viewer) { PhotoViewer(photo: $0, services: services) }
        .modifier(SourceFolderInteraction(services: services, picker: $picker, confirmation: $confirmation,
                                          reconnectConfirmation: $reconnectConfirmation,
                                          selectionError: $selectionError,
                                          isActive: isActive,
                                          onScan: { services.startScan(confirmedSource: $0) }))
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

/// Shared folder-picker and source-confirmation flow for Library scans and People completion.
struct SourceFolderInteraction: ViewModifier {
    @ObservedObject var services: AppServices
    @Binding var picker: Bool
    @Binding var confirmation: Bool
    @Binding var reconnectConfirmation: Bool
    @Binding var selectionError: String?
    var isActive = true
    let onScan: (Bool) -> Void
    var onFolderSelected: () -> Void = {}
    var onPickerCancelled: () -> Void = {}
    var onScanCancelled: () -> Void = {}

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $picker, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        services.choose(url); selectionError = nil; onFolderSelected()
                    } else { onPickerCancelled() }
                case .failure:
                    selectionError = "Folder access was cancelled or denied."; onPickerCancelled()
                }
            }
            .onChange(of: services.progress.message) { _, message in
                guard isActive, message == ScanError.sourceConfirmationRequired.message else { return }
                presentReconnectIfRequested()
            }
            .onChange(of: isActive) { _, active in
                if active {
                    presentReconnectIfRequested()
                } else {
                    picker = false; confirmation = false; reconnectConfirmation = false
                    onScanCancelled()
                }
            }
            .onAppear {
                if isActive { presentReconnectIfRequested() }
            }
            .alert(reconnectConfirmation ? "Confirm the original source" : "Scan this folder?", isPresented: $confirmation) {
                Button(reconnectConfirmation ? "This is the original folder" : "Start scan") {
                    let confirmed = reconnectConfirmation
                    onScan(confirmed)
                    reconnectConfirmation = false
                }
                Button("Cancel", role: .cancel) {
                    if reconnectConfirmation,
                       services.progress.message == ScanError.sourceConfirmationRequired.message {
                        services.progress.message = ""
                    }
                    reconnectConfirmation = false; onScanCancelled()
                }
            } message: {
                Text(reconnectConfirmation
                    ? "The provider could not verify this folder's identity. Confirm only if this is the original drive and root folder. A same-named different folder may replace indexed content."
                    : "JPEG previews and face detection stay on this iPad. Originals remain unchanged. Existing previews remain available while source integrity is checked.")
            }
    }

    private func presentReconnectIfRequested() {
        guard isActive, services.progress.message == ScanError.sourceConfirmationRequired.message else { return }
        reconnectConfirmation = true
        confirmation = true
    }
}
