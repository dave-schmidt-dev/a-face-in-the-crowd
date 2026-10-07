import SwiftUI
import AFITCCore

extension ScanPhase {
    /// Human wording for the visible phase badge. The raw key is exposed to UI automation only,
    /// through `machineValue`. Never says "Scanning" for a paused, cancelled or failed scan.
    var statusText: String {
        switch self {
        case .ready: return "Ready"
        case .discovering: return "Finding photos"
        case .processing: return "Scanning photos"
        case .completed: return "Scan complete"
        case .cancelled: return "Scan cancelled"
        case .paused: return "Scan paused"
        case .failed: return "Scan failed"
        case .interrupted: return "Scan interrupted"
        case .cancelling: return "Cancelling scan"
        }
    }
}

/// The single compact source and scan status for a screen: one row with the source state and a
/// phase badge, plus Cancel while a scan runs. `showsDetails` (Library) adds the counts and the
/// latest scan message. Identifiers and the exact count and message strings are UI-test contract.
struct StatusView: View {
    @ObservedObject var services: AppServices
    var showsDetails = false
    @Environment(\.tokens) private var tokens

    @State private var showsScanNote = false

    /// Elsewhere the strip appears only when it says something: work is running, the scan
    /// ended in a state worth showing, the source has a problem or cached photos have no source.
    var isNoteworthy: Bool {
        showsDetails || services.isScanning || services.isRestoringSource || services.setupError != nil
            || services.progress.phase != .ready || (services.selectedFolder == nil && !services.photos.isEmpty)
    }

    var body: some View {
        if isNoteworthy { strip }
    }

    private var strip: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: DesignTokens.Spacing.xs) { source; Spacer(minLength: DesignTokens.Spacing.xs); badge }
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) { source; badge }
            }
            if services.isRestoringSource {
                ProgressView("Restoring source folder permission").accessibilityIdentifier("restoring-source")
            }
            if services.isScanning { activity }
            if showsDetails && services.progress.phase != .ready { details }
            if let error = services.setupError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(tokens.destructive).accessibilityIdentifier("setup-error")
            }
        }
        .font(.subheadline).card(raised: true).accessibilityElement(children: .contain)
    }

    private var source: some View {
        Label(sourceMessage, systemImage: "externaldrive")
            .font(.subheadline.weight(.semibold))
            .accessibilityIdentifier("source-status")
    }

    @ViewBuilder private var activity: some View {
        let cancelling = services.progress.phase == .cancelling
        HStack(spacing: DesignTokens.Spacing.xs) {
            ProgressView().accessibilityLabel("Scan activity")
            Text(services.progress.message ?? (cancelling ? "Cancellation requested" : "Discovering JPEGs"))
                .accessibilityIdentifier("scan-message")
        }
        Button("Cancel scan", action: services.cancelScan)
            .buttonStyle(.capsuleSecondary)
            .accessibilityIdentifier("cancel-scan").disabled(cancelling)
    }

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.xs) {
                Text("Discovered \(services.progress.discovered) · Processed \(services.progress.processed) · Skipped \(services.progress.skipped) · Failed \(services.progress.failed)")
                    .accessibilityIdentifier("scan-counts")
                if services.progress.phase == .completed, let message = services.progress.message, !message.isEmpty {
                    Button { showsScanNote = true } label: {
                        Image(systemName: "info.circle").frame(minWidth: DesignTokens.Layout.minimumHit, minHeight: DesignTokens.Layout.minimumHit)
                    }
                    .accessibilityLabel("About this scan")
                    .accessibilityIdentifier("scan-note")
                    .popover(isPresented: $showsScanNote) {
                        Text(message)
                            .padding(DesignTokens.Spacing.m).frame(minWidth: 260, maxWidth: 360)
                            .presentationCompactAdaptation(.popover)
                    }
                }
            }
            if services.progress.phase != .completed {
                Text(services.progress.enumerationFinished ? "Discovery complete" : "Total unknown until discovery completes")
            }
            if !services.isScanning, services.progress.phase != .completed, let message = services.progress.message {
                Text(message).accessibilityIdentifier("scan-message")
            }
        }.font(.footnote).foregroundStyle(tokens.textSecondary)
    }

    /// Scan phase as a labeled status pill; color always paired with the word.
    @ViewBuilder private var badge: some View {
        if services.progress.phase != .ready {
            let (icon, color) = phaseStyle
            HStack(spacing: DesignTokens.Spacing.xxs) {
                Image(systemName: icon).accessibilityHidden(true)
                Text(services.progress.phase.statusText)
                    .machineValue(services.progress.phase.rawValue)
                    .accessibilityIdentifier("scan-phase")
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, DesignTokens.Spacing.xs).padding(.vertical, DesignTokens.Spacing.xxs)
            .background(tokens.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(color, lineWidth: 1))
        }
    }

    private var phaseStyle: (String, Color) {
        switch services.progress.phase {
        case .completed: return ("checkmark.circle.fill", tokens.success)
        case .failed: return ("exclamationmark.octagon.fill", tokens.destructive)
        case .cancelled, .paused, .interrupted, .cancelling: return ("pause.circle.fill", tokens.warning)
        case .ready, .discovering, .processing: return ("arrow.triangle.2.circlepath", tokens.primary)
        }
    }

    private var sourceMessage: String {
        if services.isScanning { return "Checking selected folder · read only" }
        if services.selectedFolder != nil { return "Folder selected · cached previews" }
        if services.progress.phase != .ready || !services.photos.isEmpty { return "Source access not active · cached previews" }
        return "No folder selected"
    }
}
