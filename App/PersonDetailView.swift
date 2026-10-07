import SwiftUI
import AFITCCore

struct PersonDetailView: View {
    @ObservedObject var services: AppServices
    let personID: UUID
    @ObservedObject private var privacy: CatalogPrivacyService
    @ObservedObject private var presentation: AppPresentationState
    @Environment(\.tokens) private var tokens
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .largeTitle) private var portrait: CGFloat = 120
    init(services: AppServices, personID: UUID) {
        self.services = services; self.personID = personID
        presentation = services.presentation; privacy = services.privacy
    }
    private var editingName: Binding<String> { Binding(get: { presentation.drafts[personID]?.ownerText ?? "" }, set: { presentation.edit(personID, text: $0) }) }
    @State private var selectedFace: FaceItem?
    @State private var merging = false
    @State private var editing = false
    private var showsDraftEditor: Bool {
        editing || presentation.drafts[personID]?.dirty == true || presentation.drafts[personID]?.conflict != nil
    }
    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.l) {
                if let summary = services.peopleSnapshot.people.first(where: { $0.id == personID }) {
                    header(summary)
                    if showsDraftEditor {
                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) { draftEditor(summary.person) }.card()
                    }
                    DecisionStatus(services: services)
                    Text("Confirmed faces").font(.headline).foregroundStyle(tokens.textSecondary).accessibilityAddTraits(.isHeader)
                    let confirmed = services.peopleSnapshot.faces.filter { $0.state.personID == personID }
                    LazyVGrid(columns: columns, alignment: .leading, spacing: DesignTokens.Spacing.s) {
                        ForEach(confirmed) { face in
                            Button { selectedFace = face } label: {
                                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                                    FacePreview(services: services, face: face, wholePhoto: false, style: .tile)
                                    Text((face.photo.relativePath as NSString).lastPathComponent)
                                        .font(.caption).foregroundStyle(tokens.textSecondary).lineLimit(1)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            .accessibilityLabel("Correct this assignment, \(face.photo.relativePath)")
                            .accessibilityIdentifier("correct-face")
                            .optionalPresentationAnchor(confirmed.first(where: { $0.photo.id == face.photo.id })?.key == face.key ? face.photo.id : nil, section: "Person-" + personID.uuidString)
                        }
                    }
                    manage(summary)
                } else {
                    Text("This person is no longer available.")
                    if showsDraftEditor { draftEditor(nil) }
                }
            }.id("person-top").padding(DesignTokens.Spacing.l).frame(maxWidth: 960, alignment: .leading).frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
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
        .navigationBarTitleDisplayMode(.inline)
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
    private var columns: [GridItem] {
        typeSize.isAccessibilitySize ? [GridItem(.flexible())]
            : [GridItem(.adaptive(minimum: DesignTokens.Layout.photoCardMin), spacing: DesignTokens.Spacing.s)]
    }
    /// Large circular cover, name and confirmed count; stacks vertically at accessibility sizes.
    @ViewBuilder private func header(_ summary: PersonSummary) -> some View {
        let size = min(portrait, 200)
        let cover = services.peopleSnapshot.faces.first(where: { $0.key == summary.person.cover })
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: DesignTokens.Spacing.m))
            : AnyLayout(HStackLayout(alignment: .center, spacing: DesignTokens.Spacing.l))
        layout {
            if let cover {
                FacePreview(services: services, face: cover, wholePhoto: false, style: .circle(size))
            } else {
                Image(systemName: "person.crop.circle.fill").resizable().scaledToFit()
                    .frame(width: size, height: size).foregroundStyle(tokens.surfaceRaised)
                    .accessibilityLabel("Cover unavailable")
            }
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                // Wrap, never truncate or clip: the name may be long and the type size large.
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.xs) {
                    Text(summary.person.displayName).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("person-name-heading")
                    Button { editing = true } label: {
                        Image(systemName: "pencil")
                            .frame(minWidth: DesignTokens.Layout.minimumHit, minHeight: DesignTokens.Layout.minimumHit)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Edit name")
                    .accessibilityIdentifier("edit-person-name")
                }
                Text(confirmedPhotoPhrase(summary.confirmedPhotoCount)).font(.headline)
                    .foregroundStyle(tokens.textSecondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("person-confirmed-count")
                if PersonNames.isAmbiguous(summary.person, among: services.peopleSnapshot.people.map(\.person)) {
                    Text("Record \(personID.uuidString.prefix(4))").font(.footnote).foregroundStyle(tokens.textSecondary)
                        .accessibilityIdentifier("person-record")
                }
                if summary.person.mergedInto != nil {
                    Text("Merged into another person. Undo restores this person and their decisions.")
                        .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
        }
    }
    /// Secondary record management sits below the photos.
    @ViewBuilder private func manage(_ summary: PersonSummary) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
            Text("Manage").font(.headline).foregroundStyle(tokens.textSecondary).accessibilityAddTraits(.isHeader)
            if summary.person.mergedInto == nil {
                Button { merging = true } label: { Label("Merge duplicate person", systemImage: "arrow.triangle.merge") }
                    .buttonStyle(CapsuleButtonStyle(prominent: false, minHeight: 48))
                    .disabled(services.isSavingDecision || services.peopleRefreshWarning != nil)
                    .accessibilityIdentifier("merge-person")
            }
            Button(role: .destructive) { privacy.request(.person(personID)) } label: {
                Label("Delete person", systemImage: "trash").foregroundStyle(tokens.destructive)
            }
            .frame(minHeight: 48).disabled(!privacy.canRequest).accessibilityIdentifier("delete-person")
            if privacy.busy { ProgressView("Checking privacy action") }
            if !privacy.message.isEmpty { Text(privacy.message).accessibilityIdentifier("person-privacy-message") }
        }
    }
    @ViewBuilder private func draftEditor(_ person: PersonRecord?) -> some View {
        Text("Name").font(.subheadline.bold()).foregroundStyle(tokens.textSecondary)
        TextField("Person name", text: editingName).textFieldStyle(.roundedBorder).accessibilityIdentifier("rename-person-name")
        if let conflict = presentation.drafts[personID]?.conflict {
            Text(conflict == .changed ? "This record changed. Review your draft against its current name before saving." : "This record is unavailable. Your draft is retained.")
                .accessibilityIdentifier("name-draft-conflict")
            if let person, person.mergedInto == nil {
                Button("Review draft with current record") { presentation.review(person) }.buttonStyle(CapsuleButtonStyle(prominent: false, minHeight: 48)).accessibilityIdentifier("review-name-draft")
                Button("Use current name") { presentation.useCurrent(person) }.buttonStyle(CapsuleButtonStyle(prominent: false, minHeight: 48)).accessibilityIdentifier("use-current-name")
            }
            Button("Discard draft") { presentation.discardDraft(personID); if let person { presentation.ensureDraft(person) } }
                .buttonStyle(CapsuleButtonStyle(prominent: false, minHeight: 48)).accessibilityIdentifier("discard-name-draft")
        }
        #if DEBUG
        if services.usesSyntheticFixture, services.launch.has("--uitest-presentation-controls"), let person {
            Button("Refresh canonical fixture") { Task { await services.decide(.rename(personID: person.id, displayName: "Changed fictional name")) } }
                .accessibilityIdentifier("change-canonical-fixture")
        }
        #endif
        Button("Save name") {
            let text = editingName.wrappedValue, session = services.catalogSessionID
            Task {
                if await services.decide(.rename(personID: personID, displayName: text)), services.sessionIsCurrent(session) {
                    presentation.acceptedCommit(personID, text: text)
                    editing = false
                }
            }
        }.buttonStyle(CapsuleButtonStyle(minHeight: 48))
            .disabled(person == nil || person?.mergedInto != nil || presentation.drafts[personID]?.conflict != nil || services.isSavingDecision || services.peopleRefreshWarning != nil)
            .accessibilityIdentifier("save-person-name")
        Button("Cancel") {
            presentation.discardDraft(personID)
            if let person { presentation.ensureDraft(person) }
            editing = false
        }.buttonStyle(CapsuleButtonStyle(prominent: false, minHeight: 48))
            .disabled(services.isSavingDecision)
            .accessibilityIdentifier("cancel-person-name")
    }

}

struct ManualFaceView: View {
    @ObservedObject var services: AppServices
    let face: FaceItem
    let initialPerson: UUID?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tokens) private var tokens
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .largeTitle) private var portrait: CGFloat = 180
    @State private var name = ""
    @State private var personID: UUID?
    @State private var context = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(spacing: 12) {
                    FacePreview(services: services, face: face, wholePhoto: false, style: .circle(min(portrait, typeSize.isAccessibilitySize ? 120 : 260)))
                    Button { context.toggle() } label: {
                        Label(context ? "Hide whole photo" : "Open whole photo context", systemImage: "photo")
                    }
                    .buttonStyle(CapsuleButtonStyle(prominent: false, minHeight: 48)).accessibilityIdentifier("whole-photo-context")
                }.frame(maxWidth: .infinity)
                if context { FacePreview(services: services, face: face, wholePhoto: true) }
                Text("This names the selected face. Other faces need separate decisions.")
                    .font(.subheadline).foregroundStyle(tokens.textSecondary)
                Text("Name").font(.subheadline.bold()).foregroundStyle(tokens.textSecondary)
                TextField("New person name", text: $name).textFieldStyle(.roundedBorder).accessibilityIdentifier("new-person-name")
                if services.peopleSnapshot.people.contains(where: { $0.person.displayName.localizedCaseInsensitiveCompare(name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame }), !name.isEmpty {
                    Text("That name already exists. Saving a new person creates a separate record.").accessibilityIdentifier("duplicate-name-warning")
                }
                if let hint = nameHint {
                    Text(hint).font(.footnote).foregroundStyle(tokens.textSecondary).accessibilityIdentifier("name-hint")
                }
                Picker(selection: $personID) {
                    Text("Create a new person").tag(nil as UUID?)
                    ForEach(activePeople) { person in
                        Text(PersonNames.label(person, among: activePeople)).tag(Optional(person.id))
                    }
                } label: {
                    Text(selectedPersonLabel).fixedSize(horizontal: false, vertical: true)
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("existing-person")
                if let personID {
                    Button("Not this person") { perform(.reject(face: face.key, personID: personID)) }
                        .buttonStyle(CapsuleButtonStyle(prominent: false, minHeight: 48)).disabled(services.isSavingDecision || services.peopleRefreshWarning != nil).accessibilityIdentifier("reject-selected-person")
                }
                Button("Unsure") { perform(.unsure(face: face.key, personID: personID)) }
                    .buttonStyle(CapsuleButtonStyle(prominent: false, minHeight: 48)).disabled(services.isSavingDecision || services.peopleRefreshWarning != nil).accessibilityIdentifier("defer-face")
                if face.state.personID != nil {
                    Button("Remove this assignment") { perform(.unassign(face: face.key)) }
                        .buttonStyle(CapsuleButtonStyle(prominent: false, minHeight: 48)).disabled(services.isSavingDecision || services.peopleRefreshWarning != nil).accessibilityIdentifier("unassign-face")
                }
                Button("Not a person · false detection") { perform(.notPerson(face: face.key)) }
                    .buttonStyle(CapsuleButtonStyle(prominent: false, minHeight: 48)).disabled(services.isSavingDecision || services.peopleRefreshWarning != nil).accessibilityIdentifier("not-a-person")
                Text("Use Not a person only for a false detection, never for an unknown person.").font(.subheadline)
                    .foregroundStyle(tokens.textSecondary)
                if let message = services.decisionError { Text(message).accessibilityIdentifier("decision-error") }
                if services.isSavingDecision { ProgressView("Saving decision") }
            }.padding(24).frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        // The primary action stays above the keyboard and the largest text, never scrolled away.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button(personID == nil ? "Save selected face" : "Confirm selected face") {
                perform(personID.map { .confirm(face: face.key, personID: $0) } ?? .name(face: face.key, displayName: name))
            }.buttonStyle(CapsuleButtonStyle(minHeight: 48)).disabled(!canSave)
                .accessibilityIdentifier("save-selected-face")
                .padding(.horizontal, 24).padding(.vertical, DesignTokens.Spacing.s)
                .frame(maxWidth: .infinity).background(tokens.background)
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
    private var activePeople: [PersonRecord] { services.peopleSnapshot.people.map(\.person).filter { $0.mergedInto == nil } }
    private var selectedPersonLabel: String {
        if let personID, let person = activePeople.first(where: { $0.id == personID }) {
            return PersonNames.label(person, among: activePeople)
        }
        return "Create a new person"
    }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Mirrors the core name rule (non-empty, at most 120, no control characters) so Save is only
    /// offered for input the catalog would accept.
    private var nameIsValid: Bool {
        !trimmedName.isEmpty && trimmedName.count <= 120
            && !trimmedName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
    private var canSave: Bool {
        !services.isSavingDecision && services.peopleRefreshWarning == nil && (personID != nil || nameIsValid)
    }
    private var nameHint: String? {
        guard personID == nil, !nameIsValid else { return nil }
        return trimmedName.count > 120 ? "Names can be up to 120 characters." : "Enter a name to save this face."
    }
}

private struct PeoplePalette: ViewModifier {
    @Environment(\.tokens) private var tokens
    func body(content: Content) -> some View {
        content.background(tokens.background).tint(tokens.primary)
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
                    Text("Source: \(PersonNames.label(source.person, among: allPeople))")
                }
                ForEach(services.peopleSnapshot.people.filter { $0.id != sourceID && $0.person.mergedInto == nil }) { summary in
                    Button("Keep \(PersonNames.label(summary.person, among: allPeople))") { select(summary.id) }
                        .buttonStyle(CapsuleButtonStyle(prominent: false, minHeight: 48)).disabled(loading || services.isSavingDecision)
                        .accessibilityIdentifier("merge-target-\(summary.id.uuidString)")
                }
                if loading { ProgressView("Reading current merge decisions") }
                if let preview {
                    Text("Keep: \(PersonNames.label(preview.survivor, among: allPeople))")
                    Text("Before: source \(preview.sourcePhotoCount), kept record \(confirmedPhotoPhrase(preview.survivorPhotoCount))")
                    Text("After selected resolutions: \(confirmedPhotoPhrase(resultCount(preview)))")
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
                                    .buttonStyle(CapsuleButtonStyle(prominent: false, minHeight: 48)).accessibilityIdentifier("merge-confirm-\(face.key.id)")
                                Button("Keep rejection · remove conflicting confirmation") { choices[face.key] = .keepRejection }
                                    .buttonStyle(CapsuleButtonStyle(prominent: false, minHeight: 48)).accessibilityIdentifier("merge-reject-\(face.key.id)")
                                Text(choices[face.key].map { $0 == .keepConfirmation ? "Chosen: confirmation" : "Chosen: rejection" } ?? "Resolution required")
                            }
                        }.card()
                    }
                    Button("Apply merge") {
                        Task {
                            let resolutions = choices.map { MergeResolution(key: $0.key, choice: $0.value) }
                            if await services.merge(preview, resolutions: resolutions) { dismiss() }
                        }
                    }.buttonStyle(CapsuleButtonStyle(minHeight: 48))
                        .disabled(loading || services.isSavingDecision || choices.count != preview.conflicts.count)
                        .accessibilityIdentifier("apply-merge")
                }
                if let message = services.decisionError {
                    Text(message).accessibilityIdentifier("decision-error")
                    if let survivorID { Button("Refresh merge preview") { select(survivorID) }.buttonStyle(CapsuleButtonStyle(prominent: false, minHeight: 48)) }
                }
                if services.isSavingDecision { ProgressView("Saving merge atomically") }
            }.padding(24).frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity)
        }.modifier(PeoplePalette()).navigationTitle("Merge duplicate person")
            .toolbar { Button("Cancel") { services.clearDecisionError(); dismiss() }.disabled(services.isSavingDecision).accessibilityIdentifier("cancel-merge") }
            .onAppear { services.clearDecisionError() }
            .onDisappear { services.clearDecisionError() }
    }
    private var allPeople: [PersonRecord] { services.peopleSnapshot.people.map(\.person) }
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
