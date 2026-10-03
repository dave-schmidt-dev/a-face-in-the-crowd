import SwiftUI

public struct RootView: View {
    @ObservedObject public var services: AppServices
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.colorScheme) private var colorScheme
    @State private var selection: Section = .library
    @State private var navigationPaths: [Section: [UUID]] = [:]
    @State private var settingsPresented = false

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

    public init(services: AppServices) { self.services = services }

    private var background: Color { token(dark: 0x141719, light: 0xF4EFE6) }
    private var surface: Color { token(dark: 0x20262A, light: 0xFFFDF8) }
    private var text: Color { token(dark: 0xF4EFE6, light: 0x1A1A1A) }
    private var secondary: Color { token(dark: 0xC2CBD0, light: 0x4E5960) }
    private var primary: Color { token(dark: 0x7EC5E8, light: 0x0F4C81) }
    private var onPrimary: Color { token(dark: 0x102331, light: 0xFFFFFF) }

    public var body: some View {
        Group {
            if sizeClass == .regular && !ProcessInfo.processInfo.arguments.contains("--uitest-compact") {
                NavigationSplitView {
                    List(Section.allCases) { section in
                        Button { select(section) } label: {
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
        .tint(primary)
        .foregroundStyle(text)
        .sheet(isPresented: $settingsPresented) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Your photos stay on your drive.").font(.headline)
                    Text("JPEG previews and face detection run locally. Catalog and previews are private app data; your originals remain on the selected drive.")
                        .foregroundStyle(secondary)
                    Spacer()
                }
                .padding(24).frame(maxWidth: .infinity, alignment: .leading)
                .background(background)
                .navigationTitle("Settings")
                .toolbar { Button("Done") { settingsPresented = false } }
            }
        }
    }

    private var sectionSelection: Binding<Section> {
        Binding(get: { selection }, set: { select($0) })
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
        }
    }

    private var settingsButton: some View {
        Button { settingsPresented = true } label: {
            Label("Settings", systemImage: "gearshape").frame(minHeight: 44)
        }
        .accessibilityIdentifier("settings")
    }

    private func content(_ section: Section) -> some View {
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
            .padding(24).frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(background)
        .navigationTitle(section.rawValue)
        .accessibilityIdentifier("screen-\(section.rawValue)")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { settingsButton } }
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
