import SwiftUI
import AFITCCore

struct PersonDetailView: View {
    @ObservedObject var services: AppServices
    let personID: UUID
    let surface: Color
    let secondary: Color
    @ObservedObject private var privacy: CatalogPrivacyService
    @ObservedObject private var presentation: AppPresentationState
    init(services: AppServices, personID: UUID, surface: Color, secondary: Color) {
        self.services = services; self.personID = personID; self.surface = surface; self.secondary = secondary
        presentation = services.presentation; privacy = services.privacy
    }
    private var editingName: Binding<String> { Binding(get: { presentation.drafts[personID]?.ownerText ?? "" }, set: { presentation.edit(personID, text: $0) }) }
    @State private var selectedFace: FaceItem?
    @State private var merging = false
    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let summary = services.peopleSnapshot.people.first(where: { $0.id == personID }) {
                    Text(summary.person.displayName).font(.largeTitle.bold())
                    Text("Record \(personID.uuidString.prefix(8))").font(.caption)
                    Text("\(summary.confirmedPhotoCount) confirmed photos").accessibilityIdentifier("person-confirmed-count")
                    Text("Possible matching unavailable. These decisions are manual.").foregroundStyle(secondary)
                    if let cover = services.peopleSnapshot.faces.first(where: { $0.key == summary.person.cover }) {
                        FacePreview(services: services, face: cover, wholePhoto: false)
                    }
                    if let survivor = summary.person.mergedInto {
                        Text("Merged into record \(survivor.uuidString.prefix(8)). Undo restores this record and its decisions.")
                    } else {
                        Button("Merge duplicate person") { merging = true }
                            .frame(minHeight: 48).disabled(services.isSavingDecision || services.peopleRefreshWarning != nil)
                            .accessibilityIdentifier("merge-person")
                    }
                    if summary.person.mergedInto == nil || presentation.drafts[personID]?.dirty == true { draftEditor(summary.person) }
                    Button("Delete person", role: .destructive) { privacy.request(.person(personID)) }
                        .frame(minHeight: 48).disabled(!privacy.canRequest).accessibilityIdentifier("delete-person")
                    if privacy.busy { ProgressView("Checking privacy action") }
                    if !privacy.message.isEmpty { Text(privacy.message).accessibilityIdentifier("person-privacy-message") }
                    DecisionStatus(services: services)
                    Text("Confirmed faces").font(.title2.bold())
                    ForEach(services.peopleSnapshot.faces.filter { $0.state.personID == personID }) { face in
                        Button { selectedFace = face } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                FacePreview(services: services, face: face, wholePhoto: false)
                                Text(face.photo.relativePath)
                                Text("Correct this assignment").font(.subheadline)
                            }.padding(16).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                                .background(surface).clipShape(RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain).accessibilityIdentifier("correct-face")
                        .optionalPresentationAnchor(services.peopleSnapshot.faces.first(where: { $0.state.personID == personID && $0.photo.id == face.photo.id })?.key == face.key ? face.photo.id : nil, section: "Person-" + personID.uuidString)
                    }
                } else {
                    Text("This person is no longer available.")
                    if presentation.drafts[personID]?.dirty == true { draftEditor(nil) }
                }
            }.id("person-top").padding(24).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity)
        }
        .coordinateSpace(name: "catalog-scroll-Person-" + personID.uuidString)
        .onPreferenceChange(PresentationAnchorKey.self) { positions in
            presentation.recordVisible("Person-" + personID.uuidString, positions: positions["Person-" + personID.uuidString] ?? [:])
        }
        .onAppear {
            let available = Set(services.peopleSnapshot.faces.filter { $0.state.personID == personID }.map { $0.photo.id })
            if let id = presentation.anchor("Person-" + personID.uuidString, available: available) { proxy.scrollTo(id, anchor: .top) } else { proxy.scrollTo("person-top", anchor: .top) }
        }
        }
        .modifier(PeoplePalette())
        .navigationTitle("Person")
        .modifier(PrivacyConfirmation(privacy: privacy, person: true))
        .onAppear {
            if let person = services.peopleSnapshot.people.first(where: { $0.id == personID })?.person { presentation.ensureDraft(person) }
        }
        .sheet(isPresented: $merging) {
            NavigationStack { MergePersonView(services: services, sourceID: personID) }
        }
        .sheet(item: $selectedFace) { face in
            NavigationStack { ManualFaceView(services: services, face: face, initialPerson: personID) }
        }
    }
    @ViewBuilder private func draftEditor(_ person: PersonRecord?) -> some View {
        TextField("Person name", text: editingName).textFieldStyle(.roundedBorder).accessibilityIdentifier("rename-person-name")
        if let conflict = presentation.drafts[personID]?.conflict {
            Text(conflict == .changed ? "This record changed. Review your draft against its current name before saving." : "This record is unavailable. Your draft is retained.")
                .accessibilityIdentifier("name-draft-conflict")
            if let person, person.mergedInto == nil {
                Button("Review draft with current record") { presentation.review(person) }.frame(minHeight: 48).accessibilityIdentifier("review-name-draft")
                Button("Use current name") { presentation.useCurrent(person) }.frame(minHeight: 48).accessibilityIdentifier("use-current-name")
            }
            Button("Discard draft") { presentation.discardDraft(personID); if let person { presentation.ensureDraft(person) } }
                .frame(minHeight: 48).accessibilityIdentifier("discard-name-draft")
        }
        #if DEBUG
        if services.usesSyntheticFixture, ProcessInfo.processInfo.arguments.contains("--uitest-presentation-controls"), let person {
            Button("Refresh canonical fixture") { Task { await services.decide(.rename(personID: person.id, displayName: "Changed fictional name")) } }
                .accessibilityIdentifier("change-canonical-fixture")
        }
        #endif
        Button("Save name") {
            let text = editingName.wrappedValue, session = services.catalogSessionID
            Task {
                if await services.decide(.rename(personID: personID, displayName: text)), services.sessionIsCurrent(session) {
                    presentation.acceptedCommit(personID, text: text)
                }
            }
        }.frame(minHeight: 48)
            .disabled(person == nil || person?.mergedInto != nil || presentation.drafts[personID]?.conflict != nil || services.isSavingDecision || services.peopleRefreshWarning != nil)
            .accessibilityIdentifier("save-person-name")
    }

}

struct ManualFaceView: View {
    @ObservedObject var services: AppServices
    let face: FaceItem
    let initialPerson: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var personID: UUID?
    @State private var context = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                FacePreview(services: services, face: face, wholePhoto: false)
                Button(context ? "Hide whole photo" : "Open whole photo context") { context.toggle() }
                    .frame(minHeight: 48).accessibilityIdentifier("whole-photo-context")
                if context { FacePreview(services: services, face: face, wholePhoto: true) }
                Text("This names the selected face. Other faces need separate decisions.")
                TextField("New person name", text: $name).textFieldStyle(.roundedBorder).accessibilityIdentifier("new-person-name")
                if services.peopleSnapshot.people.contains(where: { $0.person.displayName.localizedCaseInsensitiveCompare(name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame }), !name.isEmpty {
                    Text("That name already exists. Saving a new person creates a separate record.").accessibilityIdentifier("duplicate-name-warning")
                }
                Picker("Choose existing person", selection: $personID) {
                    Text("Create a new person").tag(nil as UUID?)
                    ForEach(services.peopleSnapshot.people.filter { $0.person.mergedInto == nil }) { summary in
                        Text("\(summary.person.displayName) · \(summary.id.uuidString.prefix(8))").tag(Optional(summary.id))
                    }
                }.accessibilityIdentifier("existing-person")
                Button(personID == nil ? "Save selected face" : "Confirm selected face") {
                    perform(personID.map { .confirm(face: face.key, personID: $0) } ?? .name(face: face.key, displayName: name))
                }.frame(minHeight: 48).disabled(services.isSavingDecision || services.peopleRefreshWarning != nil).accessibilityIdentifier("save-selected-face")
                if let personID {
                    Button("Not this person") { perform(.reject(face: face.key, personID: personID)) }
                        .frame(minHeight: 48).disabled(services.isSavingDecision || services.peopleRefreshWarning != nil).accessibilityIdentifier("reject-selected-person")
                }
                Button("Unsure") { perform(.unsure(face: face.key, personID: personID)) }
                    .frame(minHeight: 48).disabled(services.isSavingDecision || services.peopleRefreshWarning != nil).accessibilityIdentifier("defer-face")
                if face.state.personID != nil {
                    Button("Remove this assignment") { perform(.unassign(face: face.key)) }
                        .frame(minHeight: 48).disabled(services.isSavingDecision || services.peopleRefreshWarning != nil).accessibilityIdentifier("unassign-face")
                }
                Button("Not a person · false detection") { perform(.notPerson(face: face.key)) }
                    .frame(minHeight: 48).disabled(services.isSavingDecision || services.peopleRefreshWarning != nil).accessibilityIdentifier("not-a-person")
                Text("Use Not a person only for a false detection, never for an unknown person.").font(.subheadline)
                if let message = services.decisionError { Text(message).accessibilityIdentifier("decision-error") }
                if services.isSavingDecision { ProgressView("Saving decision") }
            }.padding(24).frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity)
        }
        .modifier(PeoplePalette())
        .navigationTitle("Selected face")
        .toolbar { Button("Cancel") { services.clearDecisionError(); dismiss() }
            .disabled(services.isSavingDecision).accessibilityIdentifier("cancel-face-form") }
        .onAppear { personID = initialPerson; services.clearDecisionError() }
    }
    private func perform(_ decision: ManualDecision) {
        Task { if await services.decide(decision) { dismiss() } }
    }
}

private struct PeoplePalette: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    private func color(_ dark: UInt32, _ light: UInt32) -> Color {
        let hex = colorScheme == .dark ? dark : light
        return Color(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
    func body(content: Content) -> some View {
        content.background(color(0x141719, 0xF4EFE6)).foregroundStyle(color(0xF4EFE6, 0x1A1A1A)).tint(color(0x7EC5E8, 0x0F4C81))
    }
}

struct MergePersonView: View {
    @ObservedObject var services: AppServices
    let sourceID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var survivorID: UUID?
    @State private var preview: MergePreview?
    @State private var choices: [FaceKey: MergeChoice] = [:]
    @State private var loading = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Choose the record to keep").font(.title2.bold())
                Text("The source record is archived. Only existing decisions move; other people and unidentified faces stay independent.")
                if let source = services.peopleSnapshot.people.first(where: { $0.id == sourceID }) {
                    Text("Source: \(source.person.displayName) · \(sourceID.uuidString.prefix(8))")
                }
                ForEach(services.peopleSnapshot.people.filter { $0.id != sourceID && $0.person.mergedInto == nil }) { summary in
                    Button("Keep \(summary.person.displayName) · \(summary.id.uuidString.prefix(8))") { select(summary.id) }
                        .frame(minHeight: 48).disabled(loading || services.isSavingDecision)
                        .accessibilityIdentifier("merge-target-\(summary.id.uuidString)")
                }
                if loading { ProgressView("Reading current merge decisions") }
                if let preview {
                    Text("Keep: \(preview.survivor.displayName) · \(preview.survivor.id.uuidString.prefix(8))")
                    Text("Before: source \(preview.sourcePhotoCount), kept record \(preview.survivorPhotoCount) confirmed photos")
                    Text("After selected resolutions: \(resultCount(preview)) confirmed photos")
                        .accessibilityIdentifier("merge-result-count")
                    Text("Resolve every contradictory face explicitly. No choice is selected for you.")
                    ForEach(preview.faces) { face in
                        VStack(alignment: .leading, spacing: 12) {
                            FacePreview(services: services, face: face, wholePhoto: false)
                            Text(face.photo.relativePath).font(.caption)
                            DisclosureGroup("Whole photo context") { FacePreview(services: services, face: face, wholePhoto: true) }
                            Text(face.state.personID == preview.source.id ? "Confirmed source record" :
                                 face.state.personID == preview.survivor.id ? "Confirmed kept record" : "No confirmation for either record")
                            if !face.state.rejectedPeople.isDisjoint(with: [preview.source.id, preview.survivor.id]) {
                                Text("A rejection also exists for these records.")
                            }
                            if preview.conflicts.contains(face.key) {
                                Button("Keep confirmation") { choices[face.key] = .keepConfirmation }
                                    .frame(minHeight: 48).accessibilityIdentifier("merge-confirm-\(face.key.id)")
                                Button("Keep rejection · remove conflicting confirmation") { choices[face.key] = .keepRejection }
                                    .frame(minHeight: 48).accessibilityIdentifier("merge-reject-\(face.key.id)")
                                Text(choices[face.key].map { $0 == .keepConfirmation ? "Chosen: confirmation" : "Chosen: rejection" } ?? "Resolution required")
                            }
                        }.padding(16).background(.secondary.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    Button("Apply merge") {
                        Task {
                            let resolutions = choices.map { MergeResolution(key: $0.key, choice: $0.value) }
                            if await services.merge(preview, resolutions: resolutions) { dismiss() }
                        }
                    }.frame(minHeight: 48)
                        .disabled(loading || services.isSavingDecision || choices.count != preview.conflicts.count)
                        .accessibilityIdentifier("apply-merge")
                }
                if let message = services.decisionError {
                    Text(message).accessibilityIdentifier("decision-error")
                    if let survivorID { Button("Refresh merge preview") { select(survivorID) }.frame(minHeight: 48) }
                }
                if services.isSavingDecision { ProgressView("Saving merge atomically") }
            }.padding(24).frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity)
        }.modifier(PeoplePalette()).navigationTitle("Merge duplicate person")
            .toolbar { Button("Cancel") { services.clearDecisionError(); dismiss() }.disabled(services.isSavingDecision).accessibilityIdentifier("cancel-merge") }
            .onAppear { services.clearDecisionError() }
            .onDisappear { services.clearDecisionError() }
    }
    private func select(_ id: UUID) {
        survivorID = id; preview = nil; choices = [:]; loading = true
        Task {
            let result = await services.previewMerge(source: sourceID, survivor: id)
            guard survivorID == id else { return }
            preview = result; loading = false
        }
    }
    private func resultCount(_ preview: MergePreview) -> Int {
        Set(preview.faces.filter {
            ($0.state.personID == preview.source.id || $0.state.personID == preview.survivor.id) && choices[$0.key] != .keepRejection
        }.map { $0.key.photoID }).count
    }
}
