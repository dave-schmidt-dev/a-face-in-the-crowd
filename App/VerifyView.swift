import SwiftUI
import AFITCCore

/// Verify tab shell for evaluation-only suggestions. Recognition is not qualified; nothing on
/// this screen confirms a face. Scan progress and Cancel live in the one compact status strip
/// above (`RootView`). The noun on screen is "Suggestions"; long explanations sit behind an info
/// popover and the timing statistics behind a Details disclosure.
struct VerifyView: View {
    @ObservedObject var services: AppServices
    @ObservedObject var suggestions: SuggestionService
    @Environment(\.tokens) private var tokens
    @State private var confirmingClear = false
    @State private var explaining = false
    @State private var explainingBanner = false
    private var secondary: Color { tokens.textSecondary }

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
            compactControlRow
            if !suggestions.isEnabled {
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.xs) {
                    Text("Suggestions are off.").foregroundStyle(secondary).accessibilityIdentifier("verify-off")
                    Button { explaining = true } label: { Label("How suggestions work", systemImage: "info.circle") }
                        .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("verify-explain")
                        .popover(isPresented: $explaining) {
                            Text("When on, unidentified faces are compared with faces you confirmed and possible matches are listed for your review. Face details stay in memory on this iPad and are cleared when you turn this off or close the app.")
                                .padding().frame(maxWidth: 360).presentationCompactAdaptation(.popover)
                                .accessibilityIdentifier("verify-off-detail")
                        }
                }
            } else if !suggestions.hasConfirmedFaces {
                Text("No confirmed faces yet. Name faces in People so suggestions have examples to compare.")
                    .foregroundStyle(secondary)
                    .accessibilityIdentifier("verify-no-confirmed-faces")
            } else {
                indexFullNotice
                jobNotices
                resultSection
            }
            if suggestions.isEnabled { statsSection }
        }
        .confirmationDialog("Clear face details?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear face details", role: .destructive) {
                // Clearing mid-scan would silently discard the rest of that scan's details.
                if !services.isScanning { services.faceEmbedding.invalidate() }
            }
            Button("Keep face details", role: .cancel) {}
        } message: {
            Text("Suggestions stay unavailable until Find face details runs again. Confirmed people and decisions are not changed.")
        }
    }

    private var compactControlRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DesignTokens.Spacing.m) {
                controlRowItems(compact: true)
            }
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
                controlRowItems(compact: false)
            }
        }
    }

    @ViewBuilder
    private func controlRowItems(compact: Bool) -> some View {
        Toggle(isOn: Binding(get: { suggestions.isEnabled }, set: { suggestions.setEnabled($0) })) {
            Text("Suggestions").font(.headline)
        }
        .fixedSize(horizontal: compact, vertical: false)
        .frame(minHeight: 48)
        .padding(.horizontal, DesignTokens.Spacing.m)
        .background(tokens.surface, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous))
        .disabled(services.isQuiescingCatalog)
        .accessibilityIdentifier("evaluation-suggestions-toggle")

        if suggestions.isEnabled && suggestions.hasConfirmedFaces && !suggestions.jobActive && !services.isScanning {
            Button { services.startScan() } label: {
                Label("Find face details", systemImage: "faceid")
            }
            .buttonStyle(CapsuleButtonStyle(minHeight: 48))
            .disabled(!services.canStart || services.selectedFolder == nil)
            .accessibilityValue("\(suggestions.finishedJobs)")
            .accessibilityIdentifier("verify-find-face-details")

            if suggestions.indexedFaces > 0 {
                Button("Clear face details", role: .destructive) { confirmingClear = true }
                    .foregroundStyle(tokens.destructive)
                    .frame(minHeight: 48)
                    .accessibilityIdentifier("verify-clear-face-details")
            }
        }
    }

    /// Names the remedy, not just the state: clearing frees room and Find face details refills it.
    @ViewBuilder private var indexFullNotice: some View {
        if suggestions.indexFullMessage != nil {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Label(SuggestionService.indexFullText, systemImage: "tray.full")
                    .font(.headline).accessibilityIdentifier("verify-index-full")
                Text("Some photos were left out. Clear face details to make room, then choose Find face details to include the rest.")
                    .font(.subheadline).foregroundStyle(secondary)
                if !services.isScanning {
                    Button("Clear face details", role: .destructive) { confirmingClear = true }
                        .buttonStyle(.capsuleDestructive)
                        .accessibilityIdentifier("verify-index-full-clear")
                }
            }.card(raised: true)
        }
    }

    @ViewBuilder private var jobNotices: some View {
        if suggestions.jobActive {
            ProgressView("Finding face details").accessibilityIdentifier("verify-job-progress")
            if let reason = suggestions.pauseReason {
                Text(reason).accessibilityIdentifier("verify-pause-reason")
            }
        } else if services.isScanning {
            Text("This scan started before suggestions were turned on. Find face details after it finishes.")
                .foregroundStyle(secondary)
                .accessibilityIdentifier("verify-scan-without-job")
        } else {
            if suggestions.indexedFaces == 0 {
                Text("Face details are not ready. Finding them reads your photo folder once and keeps the details in memory only.")
                    .foregroundStyle(secondary)
                    .accessibilityIdentifier("verify-index-empty")
            }
            if services.selectedFolder == nil {
                Text("Choose the photo folder in Library first.").foregroundStyle(secondary)
                    .accessibilityIdentifier("verify-needs-folder")
            }
        }
    }

    @ViewBuilder private var resultSection: some View {
        if suggestions.indexedFaces > 0 {
            VStack(alignment: .leading, spacing: 16) {
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
                if let result = suggestions.result {
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
                } else if suggestions.isComputing {
                    ProgressView("Ranking suggestions").accessibilityIdentifier("verify-ranking")
                }
            }
        }
    }

    /// One card at a time from the session-local queue.
    @ViewBuilder private func review(_ result: SuggestionResult) -> some View {
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

    /// Counts and timings only; never names, paths or vectors.
    @ViewBuilder private var statsSection: some View {
        let stats = suggestions.stats
        if suggestions.indexedFaces > 0 || !stats.durations.isEmpty {
            DisclosureGroup("Details") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(suggestions.indexedFaces) faces in memory · \(stats.indexedPhotos) photos indexed this session")
                    if let p50 = stats.p50, let p95 = stats.p95 {
                        Text("Per-photo time p50 \(seconds(p50)) · p95 \(seconds(p95)) · \(stats.durations.count) photos timed")
                    }
                }
                .font(.footnote).foregroundStyle(secondary).frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("verify-job-stats")
            }
            .font(.subheadline).accessibilityIdentifier("verify-details")
        }
    }

    /// A record suffix is shown only when another active person shares the suggested name.
    private func showsRecord(_ personID: UUID) -> Bool {
        let people = services.peopleSnapshot.people.map(\.person)
        return people.first { $0.id == personID }.map { PersonNames.isAmbiguous($0, among: people) } ?? false
    }

    private func seconds(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2))) + " s"
    }
}
