import SwiftUI

public struct RootView: View {
    @ObservedObject public var services: AppServices
    @ObservedObject private var backup: CatalogBackupService
    @ObservedObject private var protection: PrivacyProtection
    @ObservedObject private var privacy: CatalogPrivacyService
    @ObservedObject private var presentation: AppPresentationState
    @ObservedObject private var searchController: SearchService
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.tokens) private var tokens
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selection: Section = .library
    /// Sidebar and detail side by side, except at accessibility text sizes where detail gets the full width.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var navigationPaths: [Section: [UUID]] = [:]
    @State private var settingsPresented = false
    /// Persisted anchors captured once per load that are waiting for their item to appear.
    @State private var pendingAnchors: [Section: UUID] = [:]

    enum Section: String, CaseIterable, Identifiable, Hashable {
        case library = "Library", people = "People", verify = "Verify", search = "Search"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .library: return "photo.on.rectangle.angled"
            case .people: return "person.2"
            case .verify: return "checkmark.circle"
            case .search: return "magnifyingglass"
            }
        }
    }

    public init(services: AppServices) {
        self.services = services; backup = services.backup; protection = services.protection; privacy = services.privacy; presentation = services.presentation; searchController = services.presentation.search
    }

    private var background: Color { tokens.background }
    private var surface: Color { tokens.surface }
    private var text: Color { tokens.textPrimary }
    private var secondary: Color { tokens.textSecondary }
    private var primary: Color { tokens.primary }

    public var body: some View {
        Group {
            if protection.blocksContent {
                ProtectedCatalogView(protection: protection, services: services)
            } else if privacy.catalogDeleted {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.m) {
                    Label("Local catalog deleted", systemImage: "checkmark.circle.fill").font(.title2.bold())
                        .foregroundStyle(tokens.success).accessibilityIdentifier("local-catalog-deleted")
                    Text("Original photos and existing exported backups were not touched.")
                    // A new catalog is only created at launch, never silently while the app is running.
                    Text("To start a new local catalog, swipe this app away in the app switcher and open it again.")
                        .foregroundStyle(tokens.textSecondary).accessibilityIdentifier("catalog-deleted-next-step")
                    Button { settingsPresented = true } label: { Label("Settings", systemImage: "gearshape") }
                        .buttonStyle(.capsuleSecondary).accessibilityIdentifier("settings")
                }.card(raised: true).padding(24).frame(maxWidth: 560)
            } else if privacy.blocksActions {
                VStack(spacing: 16) {
                    Text("Catalog privacy action").font(.title2)
                    Text(privacy.message).accessibilityIdentifier("privacy-maintenance-message")
                    Button("Open Settings") { settingsPresented = true }.frame(minHeight: 48).accessibilityIdentifier("privacy-open-settings")
                }.padding(24)
            } else if sizeClass == .regular && !ProcessInfo.processInfo.arguments.contains("--uitest-compact") {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    List(Section.allCases) { section in
                        let selected = selection == section
                        Button { if !services.isQuiescingCatalog { select(section) } } label: {
                            Label(section.rawValue, systemImage: section.symbol)
                                .symbolVariant(selected ? .fill : .none)
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(selected ? tokens.onPrimary : text)
                        .listRowBackground(RoundedRectangle(cornerRadius: DesignTokens.Radius.control, style: .continuous)
                            .fill(selected ? primary : Color.clear).padding(.horizontal, 8))
                        .listRowSeparator(.hidden)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityIdentifier("navigate-\(section.rawValue)")
                    }
                    .scrollContentBackground(.hidden)
                    .background(surface)
                    .navigationTitle("A Face in the Crowd")
                    .navigationBarTitleDisplayMode(.inline)
                } detail: {
                    navigationStack(for: selection)
                }
            } else {
                TabView(selection: sectionSelection) {
                    ForEach(Section.allCases) { section in
                        navigationStack(for: section)
                            .tabItem { Label(section.rawValue, systemImage: section.symbol) }
                            .tag(section)
                    }
                }
            }
        }
        .safeAreaInset(edge: .top) {
            if services.isQuiescingCatalog, !protection.blocksContent {
                VStack {
                    Text(privacy.blocksActions ? "Catalog work is paused for the privacy action." : "Catalog work is paused while preparing recovery.")
                        .foregroundStyle(secondary)
                        .accessibilityIdentifier("catalog-session-quiescing")
                    Button(privacy.blocksActions ? "Open Settings" : "Open recovery") { settingsPresented = true }
                        .accessibilityIdentifier("open-catalog-recovery")
                }.padding(8)
            }
            #if DEBUG
            if services.usesSyntheticFixture, ProcessInfo.processInfo.arguments.contains("--uitest-session-controls") {
                VStack {
                    Text(services.sessionProbe).font(.caption).accessibilityIdentifier("catalog-session-probe")
                    if ProcessInfo.processInfo.arguments.contains("--uitest-protected-controls") {
                        Button("Synthetic unavailable event", action: protection.syntheticWill).accessibilityIdentifier("protected-synthetic-will")
                        Text(backup.retainedPreparedProbe).accessibilityIdentifier("protected-retained-backup-probe")
                    }
                    HStack {
                        Button("Pause session") {
                            Task { await services.quiesceCatalogSession(seconds:
                                ProcessInfo.processInfo.arguments.contains("--uitest-session-short-timeout") ? 0.25 : 15) }
                        }
                            .accessibilityIdentifier("quiesce-session")
                        Button("Release held work") { services.releaseHeldSessionWork() }
                            .accessibilityIdentifier("release-session-work")
                        Button("Try source admission") { services.chooseSyntheticFixture() }
                            .accessibilityIdentifier("probe-session-admission")
                    }.buttonStyle(.bordered)
                }.padding(8)
            }
            #endif
        }
        .onChange(of: services.catalogSessionID) { navigationPaths = [:] }
        // Tint only: a blanket foregroundStyle here would flatten default buttons into captions.
        .tint(primary)
        .onChange(of: protection.blocksContent) { if protection.blocksContent { settingsPresented = false } }
        .onAppear { if dynamicTypeSize.isAccessibilitySize { columnVisibility = .detailOnly } }
        .onChange(of: dynamicTypeSize) { columnVisibility = dynamicTypeSize.isAccessibilitySize ? .detailOnly : .all }
        .sheet(isPresented: $settingsPresented) {
            SettingsView(services: services, backup: services.backup)
        }
    }

    private var sectionSelection: Binding<Section> {
        Binding(get: { selection }, set: { if !services.isQuiescingCatalog { select($0) } })
    }

    /// Switching sections keeps each section's pushed screens; selecting the section that is
    /// already showing pops it to its root. A person archived or deleted meanwhile is dropped.
    private func select(_ section: Section) {
        if selection == section { navigationPaths[section] = [] }
        let live = Set(services.peopleSnapshot.people.filter { $0.person.mergedInto == nil }.map(\.id))
        navigationPaths[section] = navigationPaths[section, default: []].filter { live.contains($0) }
        selection = section
    }

    /// Save warnings and retry rows. Applied to each screen inside its NavigationStack, because an
    /// inset on the split view or tab root is not honoured by a nested (pushed) ScrollView and
    /// would cover the screen's last control.
    @ViewBuilder private var bottomStatus: some View {
        if !protection.blocksContent, presentation.warning != nil || !protection.blocksContent && presentation.saveFeedback != nil {
            VStack(spacing: 8) {
                if let warning = presentation.warning { Text(warning).font(.footnote).accessibilityIdentifier("presentation-save-warning") }
                if let feedback = presentation.saveFeedback { Text(feedback).font(.caption).accessibilityIdentifier("presentation-save-status") }
                if presentation.saveFailed {
                    Button("Retry saving inputs", action: presentation.retrySavingInputs)
                        .frame(minHeight: 44).disabled(!presentation.canRetrySavingInputs)
                        .accessibilityIdentifier("retry-presentation-save")
                }
            }.padding(8)
        }
        #if DEBUG
        if services.usesSyntheticFixture, ProcessInfo.processInfo.arguments.contains("--uitest-presentation-controls") {
            VStack {
                Text(presentation.persistenceProbe).font(.caption).accessibilityIdentifier("presentation-persistence-probe")
                Button("Flush saved inputs") { Task { await presentation.preserveInputsForTest() } }
                    .accessibilityIdentifier("flush-presentation-inputs")
                if ProcessInfo.processInfo.arguments.contains("--uitest-presentation-save-retry") {
                    Text(presentation.saveFixtureProbe).accessibilityIdentifier("presentation-save-fixture-probe")
                    HStack {
                        Button("Block input saving") { presentation.setSaveObstructionForTest(create: true) }.accessibilityIdentifier("block-presentation-save")
                        Button("Repair input saving") { presentation.setSaveObstructionForTest(create: false) }.accessibilityIdentifier("repair-presentation-save")
                    }.disabled(services.isQuiescingCatalog)
                }
            }
        }
        #endif
    }

    private func withBottomStatus<Screen: View>(_ screen: Screen) -> some View {
        screen.safeAreaInset(edge: .bottom) { bottomStatus }
    }

    private func navigationStack(for section: Section) -> some View {
        let path = Binding<[UUID]>(get: { navigationPaths[section, default: []] },
                                   set: { navigationPaths[section] = $0 })
        return NavigationStack(path: path) {
            withBottomStatus(content(section))
                .navigationDestination(for: UUID.self) { personID in
                    // Same single gear on pushed screens, so Settings stays reachable from Person
                    // now that the sidebar footer entry point is gone (CLEAR C3).
                    withBottomStatus(PersonDetailView(services: services, personID: personID))
                        .toolbar { ToolbarItem(placement: .topBarTrailing) { settingsButton } }
                        .modifier(UndoToolbar(services: services))
                }
        }.id("\(section.rawValue)-\(services.catalogSessionID)").disabled(services.isQuiescingCatalog)
    }

    private var settingsButton: some View {
        Button { settingsPresented = true } label: {
            Label("Settings", systemImage: "gearshape").frame(minHeight: 44)
        }
        .accessibilityIdentifier("settings")
    }

    private func content(_ section: Section) -> some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // One compact status strip per screen, first; Library draws its own around the grid.
                if section != .library { StatusView(services: services) }
                if section == .library {
                    LibraryView(services: services)
                } else if section == .people {
                    PeopleView(services: services)
                } else if section == .search {
                    SearchView(services: services)
                } else {
                    VerifyView(services: services, suggestions: services.suggestions)
                }
            }
            .id("catalog-top-" + section.rawValue)
            .padding(DesignTokens.Spacing.l).frame(maxWidth: 960, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .coordinateSpace(name: "catalog-scroll-" + section.rawValue)
        .onPreferenceChange(PresentationAnchorKey.self) { positions in
            presentation.recordVisible(section.rawValue, positions: positions[section.rawValue] ?? [:])
        }
        .onAppear { restoreAnchor(section, proxy: proxy) }
        .onChange(of: presentation.loaded) { restoreAnchor(section, proxy: proxy) }
        .onChange(of: availableAnchors(section)) { restorePendingAnchor(section, proxy: proxy) }
        .background(background)
        .navigationTitle(section.rawValue)
        .navigationBarTitleDisplayMode(.large)
        .accessibilityIdentifier("screen-\(section.rawValue)")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { settingsButton } }
        .modifier(UndoToolbar(services: services, enabled: section == .people || section == .verify))
        .modifier(PeopleRefresh(section: section, services: services))
        }
    }
    private func availableAnchors(_ section: Section) -> Set<UUID> {
        switch section {
        case .library: return Set(services.photos.map(\.id))
        case .people: return Set(services.peopleSnapshot.people.filter { $0.person.mergedInto == nil }.map(\.id))
        case .search: return Set(searchController.visibleResults.map { $0.photo.id })
        case .verify: return []
        }
    }
    /// Restores once per appearance or load; an anchor not yet loaded waits in `pendingAnchors`.
    private func restoreAnchor(_ section: Section, proxy: ScrollViewProxy) {
        pendingAnchors[section] = nil
        if let id = presentation.anchor(section.rawValue, available: availableAnchors(section)) { proxy.scrollTo(id, anchor: .top) }
        else {
            if presentation.loaded, let saved = presentation.preferences.anchors[section.rawValue] { pendingAnchors[section] = saved }
            proxy.scrollTo("catalog-top-" + section.rawValue, anchor: .top)
        }
    }
    /// Content changes (for example photos streaming in during a scan) never move the scroll position,
    /// except to complete the single restore captured at appearance or load.
    private func restorePendingAnchor(_ section: Section, proxy: ScrollViewProxy) {
        guard let id = pendingAnchors[section], availableAnchors(section).contains(id) else { return }
        pendingAnchors[section] = nil; proxy.scrollTo(id, anchor: .top)
    }
}

/// Pull-to-refresh for People and Search: retry after a failed read or re-run current query.
private struct PeopleRefresh: ViewModifier {
    let section: RootView.Section
    @ObservedObject var services: AppServices
    func body(content: Content) -> some View {
        if section == .people {
            content.refreshable { await services.refreshPeople() }
        } else if section == .search {
            content.refreshable {
                let prefs = services.presentation.preferences.search
                let selected = SearchView.canonicalSelection(services: services)
                // Same validity rules as the screen: never silently drop unavailable records.
                let people = services.peopleSnapshot.people.map(\.person)
                guard prefs.selected.allSatisfy({ SearchView.canonicalID($0, in: people) != nil }),
                      !(prefs.mode == .only && selected.isEmpty) else { return }
                services.presentation.search.search(mode: prefs.mode, selected: selected, services: services, requestedPages: prefs.requestedPages)
            }
        } else {
            content
        }
    }
}
