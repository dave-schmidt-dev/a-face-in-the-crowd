import SwiftUI
import AFITCCore

/// The single decision surface for uncertain matches from the shared saved-analysis result.
/// Answers use the guarded, undoable decision path; this screen never starts a scan.
struct VerifyView: View {
    @ObservedObject var services: AppServices
    @ObservedObject private var suggestions: SuggestionService
    @ObservedObject private var faceGroups: FaceGroupService
    @Environment(\.tokens) private var tokens
    @State private var explainingBanner = false
    private var secondary: Color { tokens.textSecondary }

    init(services: AppServices) {
        self.services = services
        self.suggestions = services.suggestions
        self.faceGroups = services.faceGroups
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.m) {
            HStack(alignment: .center, spacing: DesignTokens.Spacing.xs) {
                Label("Review possible matches", systemImage: "person.crop.circle.badge.questionmark")
                    .foregroundStyle(tokens.warning)
                    .font(.subheadline)
                    .accessibilityIdentifier("verify-review-heading")
                Button { explainingBanner = true } label: {
                    Label("About matches", systemImage: "info.circle")
                }
                .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                .accessibilityIdentifier("verify-match-info")
                .popover(isPresented: $explainingBanner) {
                    Text("Matches come from saved face analysis and can be wrong or miss someone. Check the photo before you confirm a match.")
                        .padding().frame(maxWidth: 360).presentationCompactAdaptation(.popover)
                        .accessibilityIdentifier("verify-match-details")
                }
            }
            if let focusedPersonIDs = suggestions.focusedPersonIDs {
                HStack(alignment: .center, spacing: DesignTokens.Spacing.s) {
                    Text("Matches for \(focusedName(focusedPersonIDs))")
                        .font(.headline).accessibilityIdentifier("verify-focused-person")
                    Spacer(minLength: 0)
                    Button("Show all matches") { suggestions.showAllMatches() }
                        .buttonStyle(CapsuleButtonStyle(prominent: false, minHeight: 44))
                        .accessibilityIdentifier("verify-show-all-matches")
                }
            }
            if !suggestions.hasConfirmedFaces {
                Text("Name a matching group or face in People to find possible matches here.")
                    .foregroundStyle(secondary)
                    .accessibilityIdentifier("verify-no-confirmed-faces")
            } else {
                resultSection
            }
        }
    }

    /// The saved analysis this screen reviews, or a clear state when it is not available yet.
    /// No control here starts a scan; the remedy is an ordinary scan from Library.
    @ViewBuilder private var resultSection: some View {
        if let result = faceGroups.result, !result.memberships.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                if faceGroups.isComputing {
                    ProgressView("Updating suggestions").accessibilityIdentifier("review-updating")
                }
                if let failure = faceGroups.failureText {
                    Text(failure).accessibilityIdentifier("face-groups-failure")
                }
                if suggestions.staleNotice {
                    // Answers stay locked until the reviewer looks at the latest card on purpose.
                    VStack(alignment: .leading, spacing: 8) {
                        Label(SuggestionService.staleCardText, systemImage: "arrow.triangle.2.circlepath")
                            .accessibilityIdentifier("review-stale-notice")
                        Button("Show latest") { suggestions.showLatest() }
                            .buttonStyle(CapsuleButtonStyle(minHeight: 48))
                            .accessibilityIdentifier("review-show-latest")
                    }
                }
                // Decision errors and saving progress stay reachable after every answer.
                DecisionStatus(services: services)
                if suggestions.focusedPersonIDs != nil, suggestions.queue.current == nil,
                   suggestions.queue.skippedCount == 0 {
                    Text("No possible matches for \(focusedName(suggestions.focusedPersonIDs ?? [])) need review.")
                        .accessibilityIdentifier("verify-focused-empty")
                } else if result.suggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No possible matches need review.")
                        Text("Compared \(result.compared) · Ambiguous \(result.ambiguous)")
                            .font(.subheadline).foregroundStyle(secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("verify-none-above-threshold")
                } else {
                    review(result)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("Saved face analysis is needed before suggestions can be reviewed.", systemImage: "tray")
                    .accessibilityIdentifier("verify-saved-analysis-needed")
                Text("Scan your photo folder once from Library. Naming and reviewing never start scans.")
                    .font(.subheadline).foregroundStyle(secondary)
            }
        }
    }

    /// One card at a time from the session-local queue.
    @ViewBuilder private func review(_ result: FaceMembershipResult) -> some View {
        let queue = suggestions.queue
        if !suggestions.canReview {
            ProgressView("Updating suggestions").accessibilityIdentifier("review-updating")
        }
        if let card = queue.current {
            ReviewCard(services: services, card: card, faces: suggestions.cardFaces,
                       canAct: queue.canAnswer(card) && suggestions.canReview && !services.isSavingDecision
                           && services.peopleRefreshWarning == nil,
                       showsRecord: showsRecord(card.personID)) { action in
                // The displayed card travels with the answer; the queue refuses it if anything changed.
                Task { await suggestions.review(action, card: card) }
            }
            .id("\(card.face.id)|\(card.personID)|\(card.exemplarRevision)")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("You skipped every remaining suggestion this session.")
                    .accessibilityIdentifier("review-all-skipped")
                Button("Review skipped suggestions") { suggestions.resetSkips() }
                    .buttonStyle(CapsuleButtonStyle(prominent: false, minHeight: 48)).accessibilityIdentifier("review-show-skipped")
            }
        }
        VStack(alignment: .leading, spacing: 4) {
            Text("\(queue.remaining) to review · \(queue.skippedCount) skipped this session").font(.headline)
            if suggestions.focusedPersonIDs == nil {
                Text("Compared \(result.compared) · Ambiguous \(result.ambiguous)")
                    .font(.subheadline).foregroundStyle(secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("verify-suggestion-count")
    }

    /// A record suffix is shown only when another active person shares the suggested name.
    private func showsRecord(_ personID: UUID) -> Bool {
        let people = services.peopleSnapshot.people.map(\.person)
        return people.first { $0.id == personID }.map { PersonNames.isAmbiguous($0, among: people) } ?? false
    }

    private func focusedName(_ ids: Set<UUID>) -> String {
        let names = services.peopleSnapshot.people.compactMap { summary in
            ids.contains(summary.id) && summary.person.mergedInto == nil ? summary.person.displayName : nil
        }
        return names.isEmpty ? "selected people" : names.joined(separator: ", ")
    }
}
