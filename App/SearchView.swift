import SwiftUI
import AFITCCore

struct SearchView: View {
    @ObservedObject var services: AppServices
    @StateObject private var controller = SearchService()
    @State private var selected: Set<UUID> = []
    @State private var mode = SearchMode.together
    @State private var viewer: PhotoIdentity?
    @Environment(\.colorScheme) private var scheme
    private var tokens: DesignTokens { DesignTokens(scheme: scheme) }
    private func title(_ mode: SearchMode) -> String {
        switch mode { case .together: return "Together"; case .any: return "Any selected"; case .only: return "Only selected" }
    }
    private var activePeople: [PersonRecord] {
        services.peopleSnapshot.people.map(\.person).filter { $0.mergedInto == nil }
    }
    /// UUID aliases preserve a selection across explicit merges; names never establish identity.
    private func canonicalID(_ id: UUID) -> UUID? {
        let records = Dictionary(grouping: services.peopleSnapshot.people.map(\.person), by: \.id)
        var current = id, seen: Set<UUID> = []
        while seen.insert(current).inserted {
            guard let matches = records[current], matches.count == 1, let record = matches.first else { return nil }
            guard let next = record.mergedInto else { return current }
            current = next
        }
        return nil
    }
    private var canonicalSelection: Set<UUID> { Set(selected.compactMap { canonicalID($0) }) }
    private var selectionUnavailable: Bool { selected.contains { canonicalID($0) == nil } }
    private var chipSelection: Binding<Set<UUID>> {
        Binding(get: { canonicalSelection }, set: { value in
            let unresolved = selected.filter { canonicalID($0) == nil }
            selected = value.union(unresolved)
        })
    }
    private var sentence: String {
        let ids = canonicalSelection
        let names = activePeople.filter { ids.contains($0.id) }.map(\.displayName)
        if selectionUnavailable { return "Some selected records are unavailable. Update your selection." }
        if names.isEmpty && mode == .only { return "Select at least one confirmed person for Only selected." }
        if names.isEmpty && mode != .only { return "All catalog photos." }
        let list = names.joined(separator: ", ")
        switch mode {
        case .together: return "Photos with \(list) together. Other people may appear."
        case .any: return "Photos with any of \(list). Other people may appear."
        case .only: return "Photos with only \(list) among resolved detected faces. Detection can miss people."
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Search").font(.largeTitle.bold())
            Text("Confirmed people").font(.headline)
            if !services.hasLoadedPeopleSnapshot { Text("People unavailable. Refresh People before searching.") }
            PersonChips(people: activePeople, selected: chipSelection)
            VStack(alignment: .leading, spacing: 8) {
                ForEach([SearchMode.together, .any, .only], id: \.self) { value in
                    Button { mode = value } label: {
                        Label(title(value), systemImage: mode == value ? "checkmark.circle.fill" : "circle")
                            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    }.accessibilityIdentifier("search-mode-\(value.rawValue)")
                        .accessibilityAddTraits(mode == value ? .isSelected : [])
                }
            }
            Text(sentence).accessibilityIdentifier("query-sentence")
            if selectionUnavailable {
                Button("Clear unavailable selections") { selected = Set(selected.filter { canonicalID($0) != nil }) }
                    .frame(minHeight: 44).accessibilityIdentifier("clear-unavailable-selections")
            }
            #if DEBUG
            if services.usesSyntheticFixture, ProcessInfo.processInfo.arguments.contains("--uitest-viewer-hold-read") ||
                ProcessInfo.processInfo.arguments.contains("--uitest-viewer-fallback-error-after-release") {
                Text(services.syntheticViewerProbe).font(.caption).accessibilityIdentifier("viewer-request-probe")
            }
            #endif
            Text("Only confirmed identities included. Possible matches unavailable.")
                .font(.caption).foregroundStyle(tokens.secondary).accessibilityIdentifier("possible-unavailable")
            Button("Show photos") { controller.search(mode: mode, selected: canonicalSelection, services: services) }
                .frame(minHeight: 48).disabled(controller.searching || selectionUnavailable || (mode == .only && canonicalSelection.isEmpty))
                .accessibilityIdentifier("show-photos")
            if controller.searching { ProgressView("Searching").accessibilityIdentifier("searching") }
            if let error = controller.error { Text(error).accessibilityIdentifier("search-error") }
            if let snapshot = controller.snapshot {
                Text("\(snapshot.totalCount) \(snapshot.totalCount == 1 ? "photo" : "photos")").font(.headline).accessibilityIdentifier("search-result-count")
                Text(snapshot.selectedPeople.isEmpty ? "All catalog photos" : "Confirmed: " + snapshot.selectedPeople.map(\.displayName).joined(separator: ", "))
                    .font(.caption).accessibilityIdentifier("search-snapshot")
                Button("Refresh results") { controller.search(mode: mode, selected: canonicalSelection, services: services) }
                    .frame(minHeight: 44).disabled(controller.searching || selectionUnavailable || (mode == .only && canonicalSelection.isEmpty))
                    .accessibilityIdentifier("refresh-search")
                if snapshot.query.mode == .only {
                    Text("\(snapshot.coverage.unresolvedCandidatePhotoCount) candidate \(snapshot.coverage.unresolvedCandidatePhotoCount == 1 ? "photo" : "photos") withheld for unresolved faces; \(snapshot.coverage.extraPeopleCandidatePhotoCount) \(snapshot.coverage.extraPeopleCandidatePhotoCount == 1 ? "photo has" : "photos have") extra people.")
                        .accessibilityIdentifier("only-coverage")
                }
                if snapshot.totalCount == 0 { Text("No photos match these confirmed people and this mode.").accessibilityIdentifier("search-empty") }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], spacing: 16) {
                    ForEach(controller.visibleResults, id: \.photo.id) { result in
                        Button { viewer = result.photo } label: {
                            VStack(alignment: .leading) {
                                SearchPreview(url: services.previewURL(result.photo))
                                Text(result.photo.relativePath).font(.caption).lineLimit(2)
                            }
                        }.accessibilityIdentifier("search-photo-\(result.photo.id.uuidString)")
                            .accessibilityLabel("Open photo \(result.photo.relativePath)")
                    }
                }
                if controller.visibleResults.count < snapshot.totalCount {
                    Button("Load more photos") { controller.nextPage() }.frame(minHeight: 48).accessibilityIdentifier("search-next-page")
                }
            }
        }
        .onChange(of: selected) { controller.invalidate() }
        .onChange(of: mode) { controller.invalidate() }
        .onDisappear { controller.invalidate() }
        .sheet(item: $viewer) { PhotoViewer(photo: $0, services: services) }
    }
}

private struct SearchPreview: View {
    let url: URL?
    @State private var image: UIImage?
    @State private var token = UUID()
    @State private var released = false
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { Text(released ? "Preview released for memory" : "Cached preview unavailable") }
        }.frame(maxWidth: .infinity).frame(height: 160)
            .task(id: url) {
                let current = UUID(); token = current; image = nil; released = false
                guard let url else { return }
                let work = Task.detached { () -> CGImage? in
                    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
                    defer { try? handle.close() }
                    guard let data = try? handle.read(upToCount: DecodeLimits.maximumFileBytes + 1) else { return nil }
                    return try? PreviewService.decode(data)
                }
                let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
                guard !Task.isCancelled, token == current else { return }
                image = result.map { UIImage(cgImage: $0) }
            }
            .onDisappear { token = UUID(); image = nil; released = true }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in token = UUID(); image = nil; released = true }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in token = UUID(); image = nil; released = true }
    }
}
