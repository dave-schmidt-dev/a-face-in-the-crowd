import SwiftUI

public struct RootView: View {
    @ObservedObject public var services: AppServices
    @ObservedObject private var backup: CatalogBackupService
    @ObservedObject private var protection: PrivacyProtection
    @ObservedObject private var privacy: CatalogPrivacyService
    @ObservedObject private var presentation: AppPresentationState
    @ObservedObject private var searchController: SearchService
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.colorScheme) private var colorScheme
    @State private var selection: Section = .library
    @State private var navigationPaths: [Section: [UUID]] = [:]
    @State private var settingsPresented = false
    /// Persisted anchors captured once per load that are waiting for their item to appear.
    @State private var pendingAnchors: [Section: UUID] = [:]

    enum Section: String, CaseIterable, Identifiable, Hashable {
        case library = "Library", people = "People", verify = "Verify", search = "Search"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .library: return "photo.on.rectangle"
            case .people: return "person.2"
            case .verify: return "checkmark.circle"
            case .search: return "magnifyingglass"
            }
        }
    }

    public init(services: AppServices) {
        self.services = services; backup = services.backup; protection = services.protection; privacy = services.privacy; presentation = services.presentation; searchController = services.presentation.search
    }

    private var background: Color { token(dark: 0x141719, light: 0xF4EFE6) }
    private var surface: Color { token(dark: 0x20262A, light: 0xFFFDF8) }
    private var text: Color { token(dark: 0xF4EFE6, light: 0x1A1A1A) }
    private var secondary: Color { token(dark: 0xC2CBD0, light: 0x4E5960) }
    private var primary: Color { token(dark: 0x7EC5E8, light: 0x0F4C81) }
    private var onPrimary: Color { token(dark: 0x102331, light: 0xFFFFFF) }

    public var body: some View {
        Group {
            if protection.blocksContent {
                ProtectedCatalogView(protection: protection, services: services)
            } else if privacy.catalogDeleted {
                VStack(spacing: 16) {
                    Text("Local catalog deleted").font(.title2).accessibilityIdentifier("local-catalog-deleted")
                    Text("Original photos and existing exported backups remain. Close and reopen the app to start a new local catalog.")
                    Button("Settings") { settingsPresented = true }.frame(minHeight: 48).accessibilityIdentifier("settings")
                }.padding(24)
            } else if privacy.blocksActions {
                VStack(spacing: 16) {
                    Text("Catalog privacy action").font(.title2)
                    Text(privacy.message).accessibilityIdentifier("privacy-maintenance-message")
                    Button("Open Settings") { settingsPresented = true }.frame(minHeight: 48).accessibilityIdentifier("privacy-open-settings")
                }.padding(24)
            } else if sizeClass == .regular && !ProcessInfo.processInfo.arguments.contains("--uitest-compact") {
                NavigationSplitView {
                    List(Section.allCases) { section in
                        Button { if !services.isQuiescingCatalog { select(section) } } label: {
                            Label(section.rawValue, systemImage: section.symbol)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .foregroundStyle(selection == section ? primary : text)
                        .accessibilityAddTraits(selection == section ? .isSelected : [])
                        .accessibilityIdentifier("navigate-\(section.rawValue)")
                    }
                    .scrollContentBackground(.hidden)
                    .background(surface)
                    .navigationTitle("AFITC")
                    .safeAreaInset(edge: .bottom) { settingsButton.padding(16) }
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
        .safeAreaInset(edge: .bottom) {
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
        .tint(primary)
        .foregroundStyle(text)
        .onChange(of: protection.blocksContent) { if protection.blocksContent { settingsPresented = false } }
        .sheet(isPresented: $settingsPresented) {
            SettingsView(services: services, backup: services.backup)
        }
    }

    private var sectionSelection: Binding<Section> {
        Binding(get: { selection }, set: { if !services.isQuiescingCatalog { select($0) } })
    }

    /// Section controls always show that section's root, including after a person is archived.
    private func select(_ section: Section) {
        navigationPaths[selection] = []
        navigationPaths[section] = []
        selection = section
    }

    private func navigationStack(for section: Section) -> some View {
        let path = Binding<[UUID]>(get: { navigationPaths[section, default: []] },
                                   set: { navigationPaths[section] = $0 })
        return NavigationStack(path: path) {
            content(section)
                .navigationDestination(for: UUID.self) { personID in
                    PersonDetailView(services: services, personID: personID,
                                     surface: surface, secondary: secondary)
                }
        }.id(services.catalogSessionID).disabled(services.isQuiescingCatalog)
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
                if section == .library {
                    LibraryView(services: services, surface: surface, secondary: secondary,
                                primary: primary, onPrimary: onPrimary)
                } else if section == .people {
                    PeopleView(services: services, surface: surface, secondary: secondary)
                } else if section == .search {
                    SearchView(services: services)
                } else {
                    Label(section.rawValue, systemImage: section.symbol).font(.largeTitle.bold())
                    Text(emptyMessage(section)).foregroundStyle(secondary)
                }
                StatusView(services: services).foregroundStyle(secondary)
            }
            .id("catalog-top-" + section.rawValue)
            .padding(24).frame(maxWidth: 720, alignment: .leading)
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
        .accessibilityIdentifier("screen-\(section.rawValue)")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { settingsButton } }
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

    private func emptyMessage(_ section: Section) -> String {
        switch section {
        case .people: return "People you name will appear here after a photo folder is set up."
        case .verify: return "Suggestions will need your confirmation. Verification is not available yet."
        case .search: return "Search your confirmed people after library setup and naming are available."
        case .library: return "Choose a photo folder to begin."
        }
    }

    private func token(dark: UInt32, light: UInt32) -> Color {
        let value = colorScheme == .dark ? dark : light
        return Color(red: Double((value >> 16) & 255) / 255,
                     green: Double((value >> 8) & 255) / 255,
                     blue: Double(value & 255) / 255)
    }
}
