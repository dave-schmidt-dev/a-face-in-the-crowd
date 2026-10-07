import SwiftUI
import AFITCCore

/// One unnamed group's photos with naming in place. Every action is guarded by the pinned
/// group snapshot captured from the current face states; saving a name or label keeps this
/// screen and its photos in place. Opening or naming never reads a source and never scans.
struct FaceGroupView: View {
    @ObservedObject var services: AppServices
    @ObservedObject var faceGroups: FaceGroupService
    let seed: String
    @Environment(\.tokens) private var tokens
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .largeTitle) private var portrait: CGFloat = 120
    @State private var name = ""
    @State private var labelPersonID: UUID?

    init(services: AppServices, faceGroups: FaceGroupService, seed: String) {
        self.services = services
        self.faceGroups = faceGroups
        self.seed = seed
    }

    private var group: FaceGroup? { faceGroups.result?.groups.first { $0.id == seed } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.l) {
                if let group {
                    content(group)
                } else {
                    Text("This group is no longer available. It may have been corrected elsewhere.")
                        .accessibilityIdentifier("face-group-unavailable")
                }
            }
            .id("face-group-top")
            .padding(DesignTokens.Spacing.l).frame(maxWidth: 960, alignment: .leading).frame(maxWidth: .infinity)
        }
        .modifier(PeoplePalette())
        .modifier(UndoToolbar(services: services))
        .navigationTitle("Group")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func content(_ group: FaceGroup) -> some View {
        let faces = Dictionary(uniqueKeysWithValues: services.peopleSnapshot.faces.map { ($0.key, $0) })
        let states = Dictionary(uniqueKeysWithValues: services.peopleSnapshot.faces.map { ($0.key, $0.state) })
        let members = group.members.compactMap { faces[$0] }
        let cover = faces[group.seed]
        let namedPerson = namedPerson(for: group, states: states)
        header(cover: cover, members: members, namedPerson: namedPerson)
        DecisionStatus(services: services)
        if let snapshot = group.snapshot(states: states) {
            if namedPerson != nil {
                Text("Possible matches remain separate from your confirmed examples.")
                    .font(.subheadline).foregroundStyle(tokens.textSecondary)
                    .accessibilityIdentifier("face-group-named-note")
            } else {
                naming(snapshot: snapshot)
                labeling(snapshot: snapshot)
            }
            memberGrid(members: members, snapshot: snapshot)
        } else {
            Text("This group changed while it was open. Refresh People and open it again before naming.")
                .accessibilityIdentifier("face-group-stale")
        }
    }

    /// Cover, member count and the current name once the group has one.
    @ViewBuilder private func header(cover: FaceItem?, members: [FaceItem], namedPerson: PersonSummary?) -> some View {
        let size = min(portrait, 200)
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
                if let namedPerson {
                    Text(namedPerson.person.displayName).font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader).accessibilityIdentifier("face-group-named-heading")
                } else {
                    Text("Unnamed group").font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader).accessibilityIdentifier("face-group-heading")
                }
                Text(members.count == 1 ? "1 face in this group" : "\(members.count) faces in this group")
                    .font(.headline).foregroundStyle(tokens.textSecondary)
                    .accessibilityIdentifier("face-group-member-count")
            }.frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
        }
    }

    /// The group's photos, visible before naming and retained immediately after.
    private func memberGrid(members: [FaceItem], snapshot: FaceGroupSnapshot) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
            Text("Photos").font(.headline).foregroundStyle(tokens.textSecondary).accessibilityAddTraits(.isHeader)
            let columns = typeSize.isAccessibilitySize ? [GridItem(.flexible())]
                : [GridItem(.adaptive(minimum: DesignTokens.Layout.photoCardMin), spacing: DesignTokens.Spacing.s)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: DesignTokens.Spacing.s) {
                ForEach(members) { face in
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                        FacePreview(services: services, face: face, wholePhoto: false, style: .tile)
                        Text((face.photo.relativePath as NSString).lastPathComponent)
                            .font(.caption).foregroundStyle(tokens.textSecondary).lineLimit(1)
                        Button("Not in this group") {
                            perform(.excludeGroupMember(face: face.key, group: snapshot))
                        }
                        .buttonStyle(CapsuleButtonStyle(prominent: false, minHeight: 44))
                        .disabled(services.isSavingDecision || services.peopleRefreshWarning != nil)
                        .accessibilityIdentifier("exclude-group-member")
                    }.card()
                }
            }
            Text("Not in this group is a durable correction with Undo. It excludes this face from every member of the inspected group.")
                .font(.footnote).foregroundStyle(tokens.textSecondary)
        }
    }

    /// Name in place: names exactly the inspected cover, keeps the group's photos here.
    private func naming(snapshot: FaceGroupSnapshot) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
            Text("Name this group").font(.headline).foregroundStyle(tokens.textSecondary).accessibilityAddTraits(.isHeader)
            Text("One face becomes your confirmed example. Other photos remain possible matches until you confirm them.")
                .font(.subheadline).foregroundStyle(tokens.textSecondary)
            TextField("New person name", text: $name).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("group-name-field")
            Button("Save name") {
                perform(.nameGroup(cover: snapshot.seed, group: snapshot, displayName: name))
            }
            .buttonStyle(CapsuleButtonStyle(minHeight: 48))
            .disabled(!nameIsValid || services.isSavingDecision || services.peopleRefreshWarning != nil)
            .accessibilityIdentifier("save-group-name")
        }.card()
    }

    /// Label the group to an existing person; aggregation happens through that person.
    private func labeling(snapshot: FaceGroupSnapshot) -> some View {
        let people = services.peopleSnapshot.people.filter { $0.person.mergedInto == nil }
        return VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
            Text("Add to an existing person").font(.headline).foregroundStyle(tokens.textSecondary)
                .accessibilityAddTraits(.isHeader)
            if people.isEmpty {
                Text("No existing person yet. Save a name first.").font(.subheadline)
                    .foregroundStyle(tokens.textSecondary)
            } else {
                Picker(selection: $labelPersonID) {
                    Text("Choose a person").tag(nil as UUID?)
                    ForEach(people) { summary in
                        Text(PersonNames.label(summary.person, among: people.map(\.person))).tag(Optional(summary.id))
                    }
                } label: { EmptyView() }
                .pickerStyle(.menu).accessibilityIdentifier("label-group-person")
                Button("Add to person") {
                    if let labelPersonID,
                       let person = people.first(where: { $0.id == labelPersonID }) {
                        perform(.labelGroup(cover: snapshot.seed, group: snapshot, personID: labelPersonID,
                                            exemplarRevision: person.person.exemplarRevision))
                    }
                }
                .buttonStyle(CapsuleButtonStyle(minHeight: 48))
                .disabled(labelPersonID == nil || services.isSavingDecision || services.peopleRefreshWarning != nil)
                .accessibilityIdentifier("apply-group-label")
            }
        }.card()
    }

    private func namedPerson(for group: FaceGroup, states: [FaceKey: ManualFaceState]) -> PersonSummary? {
        guard let personID = states[group.seed]?.personID else { return nil }
        return services.peopleSnapshot.people.first { $0.id == personID && $0.person.mergedInto == nil }
    }

    private func perform(_ decision: ManualDecision) {
        Task { _ = await services.decide(decision) }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Mirrors the core name rule so Save is only offered for input the catalog would accept.
    private var nameIsValid: Bool {
        !trimmedName.isEmpty && trimmedName.count <= 120
            && !trimmedName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
}
