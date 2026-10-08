import SwiftUI
import AFITCCore

struct PeopleView: View {
    @ObservedObject var services: AppServices
    @ObservedObject private var faceGroups: FaceGroupService
    @Environment(\.tokens) private var tokens
    @Environment(\.dynamicTypeSize) private var typeSize
    var isActive = true
    @State private var selectedFace: FaceItem?
    @State private var picker = false
    @State private var confirmation = false
    @State private var reconnectConfirmation = false
    @State private var selectionError: String?
    @State private var finishingAfterSourceSelection = false
    /// Local string route: the outer stack's UUID path pruning cannot pop an open group detail.
    @State private var selectedGroupSeed: String?

    init(services: AppServices, isActive: Bool = true) {
        self.services = services
        self.faceGroups = services.faceGroups
        self.isActive = isActive
    }

    var body: some View {
        let coverFaces = Dictionary(uniqueKeysWithValues: services.peopleSnapshot.faces.map { ($0.key, $0) })
        let active = services.peopleSnapshot.people.filter { $0.person.mergedInto == nil }
        let nameCounts = Dictionary(grouping: active, by: { $0.person.displayName.lowercased() }).mapValues(\.count)
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.l) {
            Text("Confirmed people").font(.headline).foregroundStyle(tokens.textSecondary)
                .accessibilityAddTraits(.isHeader).accessibilityIdentifier("people-records-start")
                .machineValue("\(active.count)")
            DecisionStatus(services: services)
            #if DEBUG
            if services.usesSyntheticFixture, services.launch.has("--uitest-refresh-burst") {
                Text(services.syntheticRefreshProbe).accessibilityIdentifier("people-refresh-probe")
            }
            #endif
            if !services.hasLoadedPeopleSnapshot {
                Text(services.peopleRefreshWarning == nil ? "Opening People data" : "People data unavailable. Cached Library photos remain available.")
                    .accessibilityIdentifier("people-data-unavailable")
            } else {
            if active.isEmpty {
                Text("Open an unnamed group to assign one name to every face in it, or name an individual face below.").foregroundStyle(tokens.textSecondary)
            } else {
                LazyVGrid(columns: columns, spacing: DesignTokens.Spacing.l) {
                    ForEach(active) { summary in
                        let card = PersonCard(services: services, summary: summary,
                                              cover: summary.person.cover.flatMap { coverFaces[$0] },
                                              showsRecord: (nameCounts[summary.person.displayName.lowercased()] ?? 0) > 1)
                        NavigationLink(value: summary.id) { card }
                            .presentationAnchor(summary.id, section: "People")
                            .buttonStyle(.plain)
                            .accessibilityLabel(card.accessibilityText)
                            .accessibilityIdentifier("person-\(summary.id.uuidString)")
                    }
                }
            }
            if faceGroups.isComputing { ProgressView("Updating face groups").accessibilityIdentifier("face-groups-progress") }
            if let failure = faceGroups.failureText { Text(failure).accessibilityIdentifier("face-groups-failure") }
            if let status = faceGroups.retrySummary.statusLine {
                Text(status).foregroundStyle(tokens.textSecondary).accessibilityIdentifier("face-analysis-status")
            }
            if !faceGroups.finishablePhotos.isEmpty {
                Button("Finish face analysis") {
                    if services.selectedFolder == nil {
                        finishingAfterSourceSelection = true
                        if services.usesSyntheticFixture { services.chooseSyntheticFixture() }
                        else { picker = true }
                    } else {
                        Task { await services.finishFaceAnalysis() }
                    }
                }
                .buttonStyle(CapsuleButtonStyle(prominent: false, minHeight: 48))
                .disabled(!services.canStart || faceGroups.isFinishingAnalysis)
                .accessibilityIdentifier("finish-face-analysis")
            }
            if let selectionError { Text(selectionError).foregroundStyle(tokens.destructive).accessibilityIdentifier("people-source-selection-error") }
            unnamedGroups(coverFaces: coverFaces)
            let unidentified = services.peopleSnapshot.faces.filter { $0.state.personID == nil && !$0.state.notPerson }
            UnidentifiedFacesCard(services: services, faces: unidentified) { selectedFace = $0 }
            let falseDetections = services.peopleSnapshot.faces.filter { $0.state.notPerson }
            if !falseDetections.isEmpty {
                DisclosureGroup("False detections") {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
                        Text("Only regions you explicitly marked Not a person appear here.").font(.subheadline)
                            .foregroundStyle(tokens.textSecondary)
                        FaceCropGrid(services: services, faces: falseDetections, identifier: "false-detection-face") { selectedFace = $0 }
                    }.padding(.top, DesignTokens.Spacing.xs)
                }
                .card()
            }
            }
        }
        .sheet(item: $selectedFace) { face in
            NavigationStack { ManualFaceView(services: services, face: face, initialPerson: nil) }
        }
        .navigationDestination(isPresented: groupPresented) {
            if let seed = selectedGroupSeed {
                FaceGroupView(services: services, faceGroups: faceGroups, seed: seed)
            }
        }
        .task { if services.peopleRefreshWarning == nil { await services.refreshPeople(); await services.faceGroups.refresh() } }
        .onChange(of: services.selectedFolder) { _, folder in
            if folder != nil { requestFinishSourceConfirmation() }
        }
        .modifier(SourceFolderInteraction(services: services, picker: $picker, confirmation: $confirmation,
                                          reconnectConfirmation: $reconnectConfirmation,
                                          selectionError: $selectionError, isActive: isActive,
                                          onScan: { confirmed in
                                              if finishingAfterSourceSelection {
                                                  finishingAfterSourceSelection = false
                                                  Task { await services.finishFaceAnalysis(confirmedSource: confirmed) }
                                              } else {
                                                  services.startScan(confirmedSource: confirmed)
                                              }
                                          },
                                          onFolderSelected: { requestFinishSourceConfirmation() },
                                          onPickerCancelled: { finishingAfterSourceSelection = false },
                                          onScanCancelled: { finishingAfterSourceSelection = false }))
    }
    private var groupPresented: Binding<Bool> {
        Binding(get: { selectedGroupSeed != nil }, set: { if !$0 { selectedGroupSeed = nil } })
    }
    private func requestFinishSourceConfirmation() {
        guard finishingAfterSourceSelection else { return }
        confirmation = true
    }
    /// Unnamed multi-face groups from the one shared saved-analysis snapshot. Opening, naming or
    /// viewing a group never reads a source and never starts a scan.
    @ViewBuilder private func unnamedGroups(coverFaces: [FaceKey: FaceItem]) -> some View {
        if let result = faceGroups.result {
            let states = Dictionary(uniqueKeysWithValues: services.peopleSnapshot.faces.map { ($0.key, $0.state) })
            let groups = result.groups.filter { group in
                group.members.count > 1
                    && group.members.allSatisfy { states[$0]?.personID == nil && states[$0]?.notPerson != true }
            }
            if !groups.isEmpty {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
                    Text("Unnamed groups").font(.headline).foregroundStyle(tokens.textSecondary)
                        .accessibilityAddTraits(.isHeader).accessibilityIdentifier("unnamed-groups-start")
                    Text("Name a matching group once to assign it to every photo.")
                        .font(.subheadline).foregroundStyle(tokens.textSecondary)
                    LazyVGrid(columns: columns, spacing: DesignTokens.Spacing.l) {
                        ForEach(groups) { group in
                            Button { selectedGroupSeed = group.id } label: {
                                FaceGroupCard(services: services,
                                              cover: group.members.compactMap { coverFaces[$0] }.first,
                                              memberCount: group.members.count)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Unnamed group, \(group.members.count) faces")
                            .accessibilityIdentifier("face-group-\(group.id)")
                        }
                    }
                }
            }
        }
    }
    private var columns: [GridItem] {
        typeSize.isAccessibilitySize ? [GridItem(.flexible())]
            : [GridItem(.adaptive(minimum: DesignTokens.Layout.personCardMin), spacing: DesignTokens.Spacing.m)]
    }
}

struct DecisionStatus: View {
    @ObservedObject var services: AppServices
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = services.decisionError { Text(message).accessibilityIdentifier("decision-error") }
            if let warning = services.peopleRefreshWarning {
                Text(warning).accessibilityIdentifier("people-refresh-warning")
                Button("Refresh People") { Task { await services.refreshPeople(); await services.faceGroups.refresh() } }
                    .buttonStyle(CapsuleButtonStyle(prominent: false, minHeight: 48)).disabled(services.isSavingDecision).accessibilityIdentifier("refresh-people")
            }
            if services.isSavingDecision { ProgressView("Saving decision") }
            else if services.isRefreshingPeople { ProgressView("Refreshing People").accessibilityIdentifier("people-refresh-progress") }
        }
    }
}

struct UndoToolbar: ViewModifier {
    @ObservedObject var services: AppServices
    var enabled: Bool = true

    func body(content: Content) -> some View {
        content.toolbar {
            if enabled && services.peopleSnapshot.undoID != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await services.undoDecision() }
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .disabled(services.isSavingDecision || services.peopleRefreshWarning != nil)
                    .accessibilityLabel("Undo last decision")
                    .accessibilityIdentifier("decision-undo")
                }
            }
        }
    }
}
