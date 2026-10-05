import SwiftUI

extension CatalogBackupService.State {
    /// Human status line for the Backup card. The raw key is exposed to UI automation only.
    var statusText: String {
        switch self {
        case .idle: return "No backup or restore in progress."
        case .preparing: return "Preparing the backup."
        case .exportPreview: return "Backup ready. Choose where to save it."
        case .validating: return "Checking the catalog backup."
        case .restorePreview: return "Backup checked. Review before replacing this catalog."
        case .writing: return "Saving the backup."
        case .draining: return "Pausing catalog work."
        case .restoring: return "Restoring the catalog."
        case .recoveryRequired: return "Recovery needed. Retry to finish."
        case .failed: return "The last backup or restore did not finish."
        case .finished: return "Last backup or restore finished."
        }
    }
}

/// Catalog backup and restore card. One inline warning sentence; the longer storage notes sit
/// behind an info popover. Identifiers and message texts are UI-test contract.
struct BackupSettingsSection: View {
    @ObservedObject var services: AppServices
    @ObservedObject var backup: CatalogBackupService
    @Environment(\.tokens) private var tokens
    @State private var showsNotes = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.m) {
            HStack(alignment: .firstTextBaseline) {
                Text("Backup and restore").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button { showsNotes = true } label: {
                    Image(systemName: "info.circle").frame(minWidth: DesignTokens.Layout.minimumHit, minHeight: DesignTokens.Layout.minimumHit)
                }
                .accessibilityLabel("About backup storage").accessibilityIdentifier("backup-notes")
                .popover(isPresented: $showsNotes) { notes }
            }
            Text("Backups are unencrypted and contain sensitive catalog data.")
                .accessibilityIdentifier("backup-privacy-warning")
            if backup.canBegin {
                actionRow
            }
            if let preview = backup.preview {
                Text(preview.summary).accessibilityIdentifier("backup-preview-summary")
                Text("Includes photo/source metadata, people, face records, manual decisions, exclusions, deferrals and the decision history. Does not include originals or source permission.")
                    .font(.footnote).foregroundStyle(tokens.textSecondary)
                    .accessibilityIdentifier("backup-included-categories")
            }
            if backup.state == .exportPreview { exportControls }
            if backup.state == .restorePreview { restoreControls }
            progress
            if !backup.message.isEmpty { Text(backup.message).accessibilityIdentifier("backup-operation-message") }
            Text(backup.state.statusText).font(.footnote).foregroundStyle(tokens.textSecondary)
                .machineValue(backup.state.rawValue)
                .accessibilityIdentifier("backup-operation-state")
            if backup.canCancel {
                Button("Cancel operation", action: backup.cancel).buttonStyle(.capsuleSecondary)
                    .accessibilityIdentifier("cancel-backup-operation")
            }
            if [.failed, .recoveryRequired].contains(backup.state) {
                Button("Retry", action: backup.retry).buttonStyle(.capsule).disabled(backup.busy)
                    .accessibilityIdentifier("retry-backup-operation")
            }
        }
        .card()
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) {
            Text("Original photos, previews and permission to access your drive are excluded.")
                .accessibilityIdentifier("backup-excluded-note")
            Text("A backup on your photo drive will not survive that drive failing. Choose independent storage when possible.")
                .accessibilityIdentifier("backup-drive-warning")
        }
        .padding(DesignTokens.Spacing.m).frame(minWidth: 260, maxWidth: 380)
        .presentationCompactAdaptation(.popover)
    }

    private var actionRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DesignTokens.Spacing.s) { actions }
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.s) { actions }
        }
    }

    @ViewBuilder private var actions: some View {
        Button("Prepare catalog backup", action: backup.prepareExport).buttonStyle(.capsule)
            .accessibilityIdentifier("prepare-backup")
        Button("Choose catalog to restore") {
            #if DEBUG
            if services.usesSyntheticFixture { backup.selectTestFolder(.restore) }
            else { backup.requestRestore() }
            #else
            backup.requestRestore()
            #endif
        }.buttonStyle(.capsuleSecondary).accessibilityIdentifier("choose-restore")
    }

    @ViewBuilder private var exportControls: some View {
        Button("Choose backup destination") {
            #if DEBUG
            if services.usesSyntheticFixture { backup.selectTestFolder(.destination) }
            else { backup.requestDestination() }
            #else
            backup.requestDestination()
            #endif
        }.buttonStyle(backup.destinationSelected ? .capsuleSecondary : .capsule)
            .disabled(backup.busy).accessibilityIdentifier("choose-backup-destination")
        Text(backup.volumeWarning).font(.footnote).foregroundStyle(tokens.textSecondary)
            .accessibilityIdentifier("backup-volume-warning")
        if backup.destinationSelected {
            Button("Export unencrypted catalog", action: backup.confirmExport).buttonStyle(.capsule)
                .disabled(backup.busy).accessibilityIdentifier("confirm-backup-export")
        }
        Button("Cancel backup", action: backup.cancelPreview).buttonStyle(.capsuleSecondary)
            .disabled(backup.busy).accessibilityIdentifier("cancel-backup-preview")
    }

    @ViewBuilder private var restoreControls: some View {
        if let revision = backup.currentRevision {
            Text("Current catalog revision \(revision)").accessibilityIdentifier("restore-current-revision")
        }
        Text("Restore replaces this catalog; it does not merge catalogs. Reconnect the original photo folder afterward.")
            .accessibilityIdentifier("restore-replacement-warning")
        Button("Keep current catalog", action: backup.cancelPreview).buttonStyle(.capsule)
            .disabled(backup.busy).accessibilityIdentifier("cancel-restore-preview")
        Button("Replace current catalog", role: .destructive, action: backup.confirmRestore)
            .buttonStyle(.capsuleDestructive).disabled(backup.busy)
            .accessibilityIdentifier("confirm-catalog-restore")
    }

    @ViewBuilder private var progress: some View {
        if let progress = backup.progress, backup.busy {
            if let total = progress.total, total > 0 {
                ProgressView(value: Double(min(progress.completed, total)), total: Double(total))
            } else { ProgressView() }
            Text("\(progress.phase) · \(progress.completed) \(progress.unit)")
                .accessibilityIdentifier("backup-progress")
        } else if backup.busy { ProgressView("Preparing catalog operation") }
    }
}
