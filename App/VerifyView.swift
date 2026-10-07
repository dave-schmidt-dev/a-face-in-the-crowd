import SwiftUI
import AFITCCore

/// Verify tab shell for evaluation-only suggestions from the one shared saved-analysis result
/// (`FaceGroupService`). Recognition is not qualified; nothing on this screen confirms a face,
/// and no control here rescans: the queue is reconciled after ordinary scans and relaunches.
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
                Label("Evaluation only · never confirms itself", systemImage: "exclamationmark.shield.fill")
                    .foregroundStyle(tokens.warning)
                    .font(.subheadline)
                    .accessibilityIdentifier("verify-evaluation-banner")
                Button { explainingBanner = true } label: {
                    Label("Evaluation details", systemImage: "info.circle")
                }
                .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                .accessibilityIdentifier("verify-evaluation-info")
                .popover(isPresented: $explainingBanner) {
                    Text("Evaluation only. Recognition is not qualified. Suggestions never confirm themselves.")
                        .padding().frame(maxWidth: 360).presentationCompactAdaptation(.popover)
                        .accessibilityIdentifier("verify-evaluation-detail")
                }
            }
            if !suggestions.hasConfirmedFaces {
                Text("No confirmed faces yet. Name faces in People so suggestions have examples to compare.")
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
                if result.suggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No suggestions above the evaluation threshold.")
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
            Text("Compared \(result.compared) · Ambiguous \(result.ambiguous)")
                .font(.subheadline).foregroundStyle(secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("verify-suggestion-count")
    }

    /// A record suffix is shown only when another active person shares the suggested name.
    private func showsRecord(_ personID: UUID) -> Bool {
        let people = services.peopleSnapshot.people.map(\.person)
        return people.first { $0.id == personID }.map { PersonNames.isAmbiguous($0, among: people) } ?? false
    }
}
