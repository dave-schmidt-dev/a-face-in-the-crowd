import SwiftUI
import AFITCCore

/// Faces and name one review card shows, looked up once per queue or People change by
/// `SuggestionService` rather than on every render.
struct ReviewCardFaces {
    let card: Suggestion
    let name: String
    let candidate: FaceItem?
    let closest: FaceItem?
    /// Up to two more confirmed examples of the suggested person, in a stable order.
    let more: [FaceItem]

    init(card: Suggestion, snapshot: PeopleSnapshot) {
        let all = snapshot.faces
        self.card = card
        name = snapshot.people.first { $0.id == card.personID }?.person.displayName ?? "Unknown person"
        candidate = all.first { $0.key == card.face }
        closest = all.first { $0.key == card.closestExemplar }
        more = Array(all.filter {
            $0.state.personID == card.personID && $0.state.isAnchor && $0.key != card.closestExemplar && $0.key != card.face
        }.sorted {
            $0.photo.relativePath != $1.photo.relativePath ? $0.photo.relativePath < $1.photo.relativePath
                : $0.key.faceID.uuidString < $1.key.faceID.uuidString
        }.prefix(2))
    }
}

/// One evaluation suggestion under human review. Recognition is not qualified: the card only
/// offers answers, and Yes goes through the guarded confirm with this card's own exemplar
/// revision and face state. Skip is session-local and writes nothing.
struct ReviewCard: View {
    @ObservedObject var services: AppServices
    let card: Suggestion
    /// Precomputed for `card`; a different card's faces are never shown under this card.
    let faces: ReviewCardFaces?
    /// False while a decision is saving or being ranked, People needs a refresh, or a stale
    /// notice awaits Show latest.
    let canAct: Bool
    /// True only when another active person shares this name, so the record disambiguates them.
    var showsRecord = false
    let onAction: (ReviewAction) -> Void
    @Environment(\.tokens) private var tokens
    private var secondary: Color { tokens.textSecondary }
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var context = false

    var body: some View {
        let shown = faces?.card == card ? faces : nil
        let name = shown?.name ?? "Unknown person"
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Is this \(name)?").font(.title2.bold())
                    .accessibilityIdentifier("review-person-name")
                HStack(spacing: 12) {
                    if showsRecord {
                        Text("Record \(card.personID.uuidString.prefix(4))")
                            .accessibilityIdentifier("review-person-record")
                    }
                    Text("Similarity \(card.score.formatted(.number.precision(.fractionLength(2))))")
                        .accessibilityIdentifier("review-similarity")
                }
                .font(.subheadline).foregroundStyle(secondary)
            }
            // Not lazy: every tile stays in the accessibility tree and reachable by scrolling.
            TileLayout(minimumWidth: 150, maximumWidth: typeSize.isAccessibilitySize ? 320 : 220,
                       maximumColumns: typeSize.isAccessibilitySize ? 1 : 4) {
                tile(shown?.candidate, caption: "Face to review", detail: shown?.candidate?.photo.relativePath,
                     identifier: "review-candidate-face")
                tile(shown?.closest, caption: "Closest example", detail: nil, identifier: "review-closest-example")
                ForEach(shown?.more ?? []) { face in
                    tile(face, caption: "Confirmed example", detail: nil, identifier: "review-example")
                }
            }
            if let candidate = shown?.candidate {
                Button { context.toggle() } label: {
                    Label(context ? "Hide whole photo" : "Open whole photo context", systemImage: "photo")
                }
                .buttonStyle(CapsuleButtonStyle(prominent: false, minHeight: 48))
                .accessibilityIdentifier("review-whole-photo-context")
                if context {
                    FacePreview(services: services, face: candidate, wholePhoto: true)
                        .accessibilityIdentifier("review-whole-photo")
                }
            }
            actions(name)
            Text("Use Not a person only for a false detection, never for an unknown person.")
                .font(.subheadline).foregroundStyle(secondary)
        }
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("review-card")
    }

    @ViewBuilder
    private func tile(_ face: FaceItem?, caption: String, detail: String?, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let face {
                FacePreview(services: services, face: face, wholePhoto: false, style: .tile)
            } else {
                Label("Preview unavailable", systemImage: "photo").frame(minHeight: 48)
            }
            Text(caption).font(.subheadline.bold())
            if let detail { Text(detail).font(.caption).foregroundStyle(secondary).lineLimit(2) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    /// Primary answers first; Unsure, false detection and Skip below. Rows stack when they do not fit.
    private func actions(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { primaryButtons(name) }
                VStack(alignment: .leading, spacing: 12) { primaryButtons(name) }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { secondaryButtons(name) }
                VStack(alignment: .leading, spacing: 12) { secondaryButtons(name) }
            }
        }
    }

    @ViewBuilder private func primaryButtons(_ name: String) -> some View {
        button("Yes", icon: "checkmark", action: .yes, label: "Yes, this is \(name)", id: "review-yes", prominent: true)
        button("Not this person", icon: "xmark", action: .notThisPerson, label: "Not \(name)", id: "review-not-this-person")
    }

    @ViewBuilder private func secondaryButtons(_ name: String) -> some View {
        button("Unsure", icon: "questionmark", action: .unsure, label: "Unsure if this is \(name)", id: "review-unsure")
        button("Not a person · false detection", icon: "person.slash", action: .notAPerson,
               label: "Not a person, false detection", id: "review-not-a-person")
        button("Skip", icon: "forward", action: .skip, label: "Skip for this session", id: "review-skip")
    }

    @ViewBuilder
    private func button(_ title: String, icon: String, action: ReviewAction, label: String, id: String,
                        prominent: Bool = false) -> some View {
        Button { onAction(action) } label: { Label(title, systemImage: icon) }
            .buttonStyle(CapsuleButtonStyle(prominent: prominent, minHeight: DesignTokens.Layout.reviewHit))
        .disabled(!canAct)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}
