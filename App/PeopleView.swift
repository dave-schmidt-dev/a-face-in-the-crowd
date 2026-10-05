import SwiftUI
import AFITCCore

struct PeopleView: View {
    @ObservedObject var services: AppServices
    @Environment(\.tokens) private var tokens
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var selectedFace: FaceItem?
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
            if services.usesSyntheticFixture, ProcessInfo.processInfo.arguments.contains("--uitest-refresh-burst") {
                Text(services.syntheticRefreshProbe).accessibilityIdentifier("people-refresh-probe")
            }
            #endif
            if !services.hasLoadedPeopleSnapshot {
                Text(services.peopleRefreshWarning == nil ? "Opening People data" : "People data unavailable. Cached Library photos remain available.")
                    .accessibilityIdentifier("people-data-unavailable")
            } else {
            if active.isEmpty {
                Text("Name an unidentified face to add a person.").foregroundStyle(tokens.textSecondary)
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
        .task { if services.peopleRefreshWarning == nil { await services.refreshPeople() } }
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
                Button("Refresh People") { Task { await services.refreshPeople() } }
                    .buttonStyle(CapsuleButtonStyle(prominent: false, minHeight: 48)).disabled(services.isSavingDecision).accessibilityIdentifier("refresh-people")
            }
            if services.peopleSnapshot.undoID != nil {
                Button { Task { await services.undoDecision() } } label: { Label("Undo last decision", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(CapsuleButtonStyle(prominent: false, minHeight: 48)).disabled(services.isSavingDecision || services.peopleRefreshWarning != nil).accessibilityIdentifier("decision-undo")
            }
            if services.isSavingDecision { ProgressView("Saving decision") }
            else if services.isRefreshingPeople { ProgressView("Refreshing People").accessibilityIdentifier("people-refresh-progress") }
        }
    }
}
