import SwiftUI
import AFITCCore

struct SearchView: View {
    @ObservedObject var services: AppServices
    @ObservedObject private var presentation: AppPresentationState
    @ObservedObject private var controller: SearchService
    init(services: AppServices) {
        self.services = services; presentation = services.presentation; controller = services.presentation.search
    }
    private var selected: Set<UUID> {
        get { presentation.preferences.search.selected }
        nonmutating set { presentation.setSearch(selected: newValue) }
    }
    private var mode: SearchMode {
        get { presentation.preferences.search.mode }
        nonmutating set { presentation.setSearch(mode: newValue) }
    }
    @State private var viewer: PhotoIdentity?
    @State private var autoSearch = false
    @State private var selectedGroupSeed: String?
    @Environment(\.tokens) private var tokens
    private func title(_ mode: SearchMode) -> String {
        switch mode { case .together: return "Together"; case .any: return "Any selected"; case .only: return "Only selected" }
    }
    private var activePeople: [PersonRecord] {
        services.peopleSnapshot.people.map(\.person).filter { $0.mergedInto == nil }
    }
    /// UUID aliases preserve a selection across explicit merges; names never establish identity.
    static func canonicalID(_ id: UUID, in people: [PersonRecord]) -> UUID? {
        let records = Dictionary(grouping: people, by: \.id)
        var current = id, seen: Set<UUID> = []
        while seen.insert(current).inserted {
            guard let matches = records[current], matches.count == 1, let record = matches.first else { return nil }
            guard let next = record.mergedInto else { return current }
            current = next
        }
        return nil
    }
    static func canonicalSelection(selected: Set<UUID>, in people: [PersonRecord]) -> Set<UUID> {
        Set(selected.compactMap { canonicalID($0, in: people) })
    }
    static func canonicalSelection(services: AppServices) -> Set<UUID> {
        canonicalSelection(selected: services.presentation.preferences.search.selected, in: services.peopleSnapshot.people.map(\.person))
    }
    private func canonicalID(_ id: UUID) -> UUID? {
        Self.canonicalID(id, in: services.peopleSnapshot.people.map(\.person))
    }
    private var canonicalSelection: Set<UUID> { Self.canonicalSelection(services: services) }
    private var selectionUnavailable: Bool { selected.contains { canonicalID($0) == nil } }
    private struct SearchKey: Equatable {
        let mode: SearchMode
        let selection: [UUID]
    }
    private var searchKey: SearchKey {
        SearchKey(mode: mode, selection: canonicalSelection.sorted { $0.uuidString < $1.uuidString })
    }
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
    @ViewBuilder private var modeButtons: some View {
        ForEach([SearchMode.together, .any, .only], id: \.self) { value in
            Button { mode = value } label: { Text(title(value)).lineLimit(1).minimumScaleFactor(0.8) }
                .buttonStyle(CapsuleButtonStyle(prominent: mode == value, minHeight: 44))
                .accessibilityIdentifier("search-mode-\(value.rawValue)")
                .accessibilityAddTraits(mode == value ? .isSelected : [])
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Confirmed people").font(.headline)
            if !services.hasLoadedPeopleSnapshot { Text("People unavailable. Refresh People before searching.") }
            PersonChips(people: activePeople, selected: chipSelection)
            // One segmented choice, not three stacked rows; wraps to a column at large text sizes.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DesignTokens.Spacing.xs) { modeButtons }
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) { modeButtons }
            }
            Text(sentence).font(.subheadline).accessibilityIdentifier("query-sentence")
            if selectionUnavailable {
                Button("Clear unavailable selections") { selected = Set(selected.filter { canonicalID($0) != nil }) }
                    .buttonStyle(.capsuleSecondary).accessibilityIdentifier("clear-unavailable-selections")
            }
            #if DEBUG
            if services.usesSyntheticFixture, services.launch.has("--uitest-viewer-hold-read") ||
                services.launch.has("--uitest-viewer-fallback-error-after-release") {
                Text(services.syntheticViewerProbe).font(.caption).accessibilityIdentifier("viewer-request-probe")
            }
            #endif
            Text(mode == .only ? "Only selected uses confirmed identities and withholds unresolved faces." : "Confirmed photos and possible matches are shown separately.")
                .font(.caption).foregroundStyle(tokens.secondary).accessibilityIdentifier("search-membership-boundary")
            if controller.snapshot == nil, !controller.searching, !autoSearch {
                Button("Show photos") {
                    autoSearch = true
                    controller.search(mode: mode, selected: canonicalSelection, services: services, requestedPages: presentation.preferences.search.requestedPages)
                }
                .buttonStyle(CapsuleButtonStyle(minHeight: 48))
                .disabled(selectionUnavailable || (mode == .only && canonicalSelection.isEmpty))
                .accessibilityIdentifier("show-photos")
            }
            if controller.searching { ProgressView("Searching").accessibilityIdentifier("searching") }
            if let error = controller.error { Text(error).accessibilityIdentifier("search-error") }
            if let snapshot = controller.snapshot {
                Text("\(snapshot.totalCount)\(snapshot.selectedPeople.isEmpty ? "" : " confirmed") \(snapshot.totalCount == 1 ? "photo" : "photos")").font(.headline).accessibilityIdentifier("search-result-count")
                // With people selected the chips above already say who was searched; this caption
                // only says what an empty selection means.
                if snapshot.selectedPeople.isEmpty {
                    Text("All catalog photos").font(.footnote).foregroundStyle(tokens.textSecondary).accessibilityIdentifier("search-snapshot")
                }
                if snapshot.query.mode == .only {
                    Text("\(snapshot.coverage.unresolvedCandidatePhotoCount) candidate \(snapshot.coverage.unresolvedCandidatePhotoCount == 1 ? "photo" : "photos") withheld for unresolved faces; \(snapshot.coverage.extraPeopleCandidatePhotoCount) \(snapshot.coverage.extraPeopleCandidatePhotoCount == 1 ? "photo has" : "photos have") extra people.")
                        .accessibilityIdentifier("only-coverage")
                }
                if snapshot.totalCount == 0 { Text("No photos match these confirmed people and this mode.").accessibilityIdentifier("search-empty") }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: DesignTokens.Spacing.s)], spacing: DesignTokens.Spacing.s) {
                    ForEach(controller.visibleResults, id: \.photo.id) { result in
                        Button { viewer = result.photo } label: {
                            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                                SearchPreview(services: services, url: services.previewURL(result.photo))
                                Text((result.photo.relativePath as NSString).lastPathComponent)
                                    .font(.caption).foregroundStyle(tokens.textSecondary).lineLimit(1)
                            }
                        }.presentationAnchor(result.photo.id, section: "Search")
                            .accessibilityIdentifier("search-photo-\(result.photo.id.uuidString)")
                            .accessibilityLabel("Open photo \(result.photo.relativePath)")
                    }
                }
                possibleResults
                if controller.visibleResults.count < snapshot.totalCount {
                    Button("Load more photos") { controller.nextPage(); presentation.requestedPage() }.buttonStyle(CapsuleButtonStyle(prominent: false, minHeight: 48)).disabled(presentation.preferences.search.requestedPages >= 64).accessibilityIdentifier("search-next-page")
                    if presentation.preferences.search.requestedPages >= 64 { Text("Refine this search to view more photos.").foregroundStyle(tokens.secondary) }
                }
            }
        }
        .onAppear { controller.refreshIfNeeded(services: services) }
        .onChange(of: services.peopleSnapshot.revision) { controller.refreshIfNeeded(services: services) }
        .onChange(of: mode) { autoSearch = true }
        .onChange(of: selected) { autoSearch = true }
        .task(id: searchKey) {
            guard autoSearch else { return }
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard !selectionUnavailable, !(mode == .only && canonicalSelection.isEmpty) else { return }
            controller.search(mode: mode, selected: canonicalSelection, services: services, requestedPages: presentation.preferences.search.requestedPages)
        }
        .navigationDestination(isPresented: Binding(get: { selectedGroupSeed != nil }, set: { if !$0 { selectedGroupSeed = nil } })) {
            if let seed = selectedGroupSeed { FaceGroupView(services: services, faceGroups: services.faceGroups, seed: seed) }
        }
        .onDisappear { controller.cancelInFlight() }
        .fullScreenCover(item: $viewer) { PhotoViewer(photo: $0, services: services) }
    }
    @ViewBuilder private var possibleResults: some View {
        if let grouped = controller.groupedSnapshot, grouped.confirmed.query.mode != .only {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
                Text("\(grouped.possibleCount) possible \(grouped.possibleCount == 1 ? "photo" : "photos")").font(.headline)
                    .accessibilityIdentifier("search-possible-count")
                if grouped.possibleCount > 0 {
                    Text("Review possible matches before confirming them.").foregroundStyle(tokens.textSecondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: DesignTokens.Spacing.s)]) {
                        ForEach(controller.visiblePossibleResults, id: \.photo.id) { result in
                            Button { viewer = result.photo } label: {
                                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                                    SearchPreview(services: services, url: services.previewURL(result.photo))
                                    Text((result.photo.relativePath as NSString).lastPathComponent).font(.caption)
                                    Text("Possible match").font(.caption).foregroundStyle(tokens.textSecondary)
                                }
                            }.accessibilityIdentifier("search-possible-photo-\(result.photo.id.uuidString)")
                                .accessibilityLabel("Open possible match \(result.photo.relativePath)")
                        }
                    }
                    let selected = grouped.confirmed.query.selectedPersonIDs
                    ForEach(grouped.membership.groups.filter { group in
                        group.members.contains { grouped.membership.memberships[$0]?.personID.map(selected.contains) == true }
                    }) { group in
                        Button("Review group · \(group.members.count) photos") { selectedGroupSeed = group.id }
                            .buttonStyle(CapsuleButtonStyle(prominent: false, minHeight: 48))
                            .accessibilityIdentifier("search-review-group-\(group.id)")
                    }
                    if controller.visiblePossibleResults.count < grouped.possibleCount {
                        Button("Load more possible matches") { controller.nextPossiblePage() }
                            .buttonStyle(CapsuleButtonStyle(prominent: false, minHeight: 48))
                            .accessibilityIdentifier("search-next-possible-page")
                    }
                }
            }
        }
    }

}

private struct SearchPreview: View {
    @ObservedObject var services: AppServices
    let url: URL?
    @State private var image: UIImage?
    @State private var token = UUID()
    @State private var released = false
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { Text(released ? "Preview released for memory" : "Cached preview unavailable") }
        }.frame(maxWidth: .infinity).frame(height: 200)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: DesignTokens.Radius.control))
            .task(id: url) {
                guard let operation = services.catalogSession.begin("search-preview") else { image = nil; return }
                defer { services.catalogSession.finish(operation) }
                let current = UUID(); token = current; image = nil; released = false
                guard let url else { return }
                let work = Task.detached { () -> CGImage? in
                    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
                    defer { try? handle.close() }
                    guard let data = try? handle.read(upToCount: DecodeLimits.maximumFileBytes + 1) else { return nil }
                    #if DEBUG
                    await services.protection.holdPreview(operation)
                    #endif
                    return try? PreviewService.decode(data)
                }
                services.catalogSession.bind(operation) { work.cancel() }
                let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
                guard services.sessionIsCurrent(operation.session), !Task.isCancelled, token == current else { return }
                image = result.map { UIImage(cgImage: $0) }
            }
            .onDisappear { token = UUID(); image = nil; released = true }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in token = UUID(); image = nil; released = true }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in token = UUID(); image = nil; released = true }
    }
}
