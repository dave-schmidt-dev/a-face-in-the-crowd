import SwiftUI
import AFITCCore

/// Confirmed person tile: circular cover face, name, confirmed-photo count.
/// The record suffix appears only when another active person shares the display name.
struct PersonCard: View {
    @ObservedObject var services: AppServices
    let summary: PersonSummary
    let cover: FaceItem?
    let showsRecord: Bool
    @Environment(\.tokens) private var tokens
    @ScaledMetric(relativeTo: .headline) private var diameter: CGFloat = 112

    var body: some View {
        let size = min(diameter, 220)
        VStack(spacing: DesignTokens.Spacing.xs) {
            if let cover {
                FacePreview(services: services, face: cover, wholePhoto: false, style: .circle(size))
            } else {
                Image(systemName: "person.crop.circle.fill").resizable().scaledToFit()
                    .frame(width: size, height: size).foregroundStyle(tokens.surfaceRaised)
                    .accessibilityLabel("Cover unavailable")
            }
            VStack(spacing: DesignTokens.Spacing.xxs) {
                Text(summary.person.displayName).font(.headline).multilineTextAlignment(.center)
                Text(summary.confirmedPhotoCount == 1 ? "1 photo" : "\(summary.confirmedPhotoCount) photos")
                    .font(.subheadline).foregroundStyle(tokens.textSecondary)
                if showsRecord {
                    Text("Record \(summary.id.uuidString.prefix(4))").font(.caption).foregroundStyle(tokens.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: DesignTokens.Layout.reviewHit)
        .padding(.vertical, DesignTokens.Spacing.xs)
        .contentShape(Rectangle())
    }

    /// Spoken label keeps the confirmed wording and the record when names collide.
    var accessibilityText: String {
        var text = "\(summary.person.displayName), \(confirmedPhotoPhrase(summary.confirmedPhotoCount))"
        if showsRecord { text += ", record \(summary.id.uuidString.prefix(4))" }
        return text
    }
}

/// Unnamed group tile: circular cover face and member count. The name is added in the group's
/// own detail screen; this tile only opens it.
struct FaceGroupCard: View {
    @ObservedObject var services: AppServices
    let cover: FaceItem?
    let memberCount: Int
    @Environment(\.tokens) private var tokens
    @ScaledMetric(relativeTo: .headline) private var diameter: CGFloat = 112

    var body: some View {
        let size = min(diameter, 220)
        VStack(spacing: DesignTokens.Spacing.xs) {
            if let cover {
                FacePreview(services: services, face: cover, wholePhoto: false, style: .circle(size))
            } else {
                Image(systemName: "person.crop.circle.fill").resizable().scaledToFit()
                    .frame(width: size, height: size).foregroundStyle(tokens.surfaceRaised)
                    .accessibilityLabel("Cover unavailable")
            }
            VStack(spacing: DesignTokens.Spacing.xxs) {
                Text("Unnamed group").font(.headline).multilineTextAlignment(.center)
                Text(memberCount == 1 ? "1 face" : "\(memberCount) faces")
                    .font(.subheadline).foregroundStyle(tokens.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: DesignTokens.Layout.reviewHit)
        .padding(.vertical, DesignTokens.Spacing.xs)
        .contentShape(Rectangle())
    }
}

/// Raised "Unidentified faces" card: count, primary Review action and a wrapping grid of
/// circular crops. A wrapping grid (not a horizontal strip) keeps every face reachable by
/// vertical scrolling at any width or text size.
struct UnidentifiedFacesCard: View {
    @ObservedObject var services: AppServices
    let faces: [FaceItem]
    let onSelect: (FaceItem) -> Void
    @Environment(\.tokens) private var tokens
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.m) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: DesignTokens.Spacing.m) { heading; Spacer(minLength: 0); review }
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) { heading; review }
            }
            if faces.isEmpty {
                Text("No unidentified detected faces in the current index.").foregroundStyle(tokens.textSecondary)
            } else {
                FaceCropGrid(services: services, faces: faces, identifier: "unidentified-face", onSelect: onSelect)
            }
            Text("Names apply only to the face you select. Detection may miss people.")
                .font(.footnote).foregroundStyle(tokens.textSecondary)
        }
        .card()
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            Text("Individual face review").font(.headline).accessibilityAddTraits(.isHeader)
            Text("\(faces.count) unidentified faces").font(.subheadline).foregroundStyle(tokens.textSecondary)
                .accessibilityIdentifier("unidentified-count")
        }
    }

    private var review: some View {
        Button { if let first = faces.first { onSelect(first) } } label: {
            Label("Review individual faces", systemImage: "person.crop.circle.badge.questionmark")
        }
        .buttonStyle(CapsuleButtonStyle(minHeight: DesignTokens.Layout.reviewHit))
        .disabled(faces.isEmpty || services.isSavingDecision || services.peopleRefreshWarning != nil)
        .accessibilityLabel("Review unidentified faces")
        .accessibilityIdentifier("review-unidentified-faces")
    }
}

/// Wrapping grid of circular face crops. Each crop is its own button whose spoken label
/// carries the face state and photo path.
struct FaceCropGrid: View {
    @ObservedObject var services: AppServices
    let faces: [FaceItem]
    let identifier: String
    let onSelect: (FaceItem) -> Void
    @Environment(\.tokens) private var tokens
    @ScaledMetric(relativeTo: .body) private var diameter: CGFloat = 76

    var body: some View {
        let size = min(diameter, 160)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: size + DesignTokens.Spacing.xs), spacing: DesignTokens.Spacing.s)],
                  alignment: .leading, spacing: DesignTokens.Spacing.s) {
            ForEach(faces) { face in
                Button { onSelect(face) } label: {
                    FacePreview(services: services, face: face, wholePhoto: false, style: .circle(size))
                        .overlay(alignment: .bottomTrailing) { badge(face) }
                        .frame(minWidth: DesignTokens.Layout.reviewHit, minHeight: DesignTokens.Layout.reviewHit)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(services.isSavingDecision || services.peopleRefreshWarning != nil)
                .accessibilityLabel("\(state(face)), \(face.photo.relativePath)")
                .accessibilityIdentifier(identifier)
            }
        }
    }

    private func state(_ face: FaceItem) -> String {
        face.state.notPerson ? "False detection" :
            (face.state.deferred || !face.state.deferredPeople.isEmpty ? "Deferred face" : "Unidentified face")
    }

    /// Decorative only: the button's spoken label already carries the state, so the badge is
    /// hidden from accessibility instead of becoming a separate SF Symbol element inside the button.
    private func badge(_ face: FaceItem) -> some View {
        badgeSymbol(face).accessibilityHidden(true)
    }

    @ViewBuilder private func badgeSymbol(_ face: FaceItem) -> some View {
        if face.state.notPerson {
            Image(systemName: "person.slash.fill").font(.caption).padding(4)
                .foregroundStyle(tokens.onPrimary).background(tokens.controlBoundary, in: Circle())
        } else if face.state.deferred || !face.state.deferredPeople.isEmpty {
            Image(systemName: "questionmark").font(.caption.bold()).padding(5)
                .foregroundStyle(tokens.onPrimary).background(tokens.warning, in: Circle())
        }
    }
}

/// Singular or plural: "1 confirmed photo", "3 confirmed photos".
func confirmedPhotoPhrase(_ count: Int) -> String {
    count == 1 ? "1 confirmed photo" : "\(count) confirmed photos"
}
