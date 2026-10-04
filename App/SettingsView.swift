import SwiftUI

struct SettingsView: View {
    @ObservedObject var services: AppServices
    @ObservedObject var backup: CatalogBackupService
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    private var tokens: DesignTokens { DesignTokens(scheme: scheme) }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Your photos stay on your drive.").font(.headline)
                        Text("JPEG previews and face detection run locally. Catalog and previews are private app data; your originals remain on the selected drive.")
                        Text(services.selectedFolder == nil ? "No source folder selected" : "Original source folder selected")
                            .accessibilityIdentifier("backup-source-state")
                    }
                    PrivacySettingsActions(services: services)
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Catalog backup and restore").font(.headline)
                        Text("Backups are unencrypted and contain sensitive catalog data. Original photos, previews and permission to access your drive are excluded.")
                            .accessibilityIdentifier("backup-privacy-warning")
                        Text("A backup on your photo drive will not survive that drive failing. Choose independent storage when possible.")
                            .accessibilityIdentifier("backup-drive-warning")
                        if backup.canBegin {
                            Button("Prepare catalog backup", action: backup.prepareExport).accessibilityIdentifier("prepare-backup")
                            Button("Choose catalog to restore") {
                                #if DEBUG
                                if services.usesSyntheticFixture { backup.selectTestFolder(.restore) }
                                else { backup.requestRestore() }
                                #else
                                backup.requestRestore()
                                #endif
                            }.accessibilityIdentifier("choose-restore")
                        }
                        if let preview = backup.preview {
                            Text(preview.summary).accessibilityIdentifier("backup-preview-summary")
                            Text("Includes photo/source metadata, people, face records, manual decisions, exclusions, deferrals and the decision history. Does not include originals or source permission.")
                                .accessibilityIdentifier("backup-included-categories")
                        }
                        if backup.state == .exportPreview {
                            Button("Choose backup destination") {
                                #if DEBUG
                                if services.usesSyntheticFixture { backup.selectTestFolder(.destination) }
                                else { backup.requestDestination() }
                                #else
                                backup.requestDestination()
                                #endif
                            }.disabled(backup.busy).accessibilityIdentifier("choose-backup-destination")
                            Text(backup.volumeWarning).accessibilityIdentifier("backup-volume-warning")
                            if backup.destinationSelected {
                                Button("Export unencrypted catalog", action: backup.confirmExport)
                                    .disabled(backup.busy).accessibilityIdentifier("confirm-backup-export")
                            }
                            Button("Cancel backup", action: backup.cancelPreview).disabled(backup.busy).accessibilityIdentifier("cancel-backup-preview")
                        }
                        if backup.state == .restorePreview {
                            if let revision = backup.currentRevision {
                                Text("Current catalog revision \(revision)").accessibilityIdentifier("restore-current-revision")
                            }
                            Text("Restore replaces this catalog; it does not merge catalogs. Reconnect the original photo folder afterward.")
                                .accessibilityIdentifier("restore-replacement-warning")
                            Button("Replace current catalog", role: .destructive, action: backup.confirmRestore)
                                .disabled(backup.busy).accessibilityIdentifier("confirm-catalog-restore")
                            Button("Keep current catalog", action: backup.cancelPreview).disabled(backup.busy).accessibilityIdentifier("cancel-restore-preview")
                        }
                        if let progress = backup.progress, backup.busy {
                            if let total = progress.total, total > 0 {
                                ProgressView(value: Double(min(progress.completed, total)), total: Double(total))
                            } else { ProgressView() }
                            Text("\(progress.phase) · \(progress.completed) \(progress.unit)")
                                .accessibilityIdentifier("backup-progress")
                        } else if backup.busy { ProgressView("Preparing catalog operation") }
                        if !backup.message.isEmpty { Text(backup.message).accessibilityIdentifier("backup-operation-message") }
                        Text(backup.state.rawValue).font(.caption).accessibilityIdentifier("backup-operation-state")
                        if backup.canCancel { Button("Cancel operation", action: backup.cancel).accessibilityIdentifier("cancel-backup-operation") }
                        if [.failed, .recoveryRequired].contains(backup.state) {
                            Button("Retry", action: backup.retry).disabled(backup.busy).accessibilityIdentifier("retry-backup-operation")
                        }
                    }
                    .buttonStyle(.bordered).controlSize(.large)
                    #if DEBUG
                    if services.usesSyntheticFixture {
                        SettingsInputFixtureControls(privacy: services.privacy, presentation: services.presentation)
                        Text(backup.probe).font(.caption).accessibilityIdentifier("backup-operation-probe")
                        Text(backup.testStatus).font(.caption).accessibilityIdentifier("backup-test-status")
                        Button("Release backup work", action: backup.releaseTestWork).accessibilityIdentifier("release-backup-work")
                        if ProcessInfo.processInfo.arguments.contains("--uitest-session-controls") {
                            Text(services.sessionProbe).font(.caption).accessibilityIdentifier("settings-session-probe")
                            Button("Release catalog work", action: services.releaseHeldSessionWork).accessibilityIdentifier("settings-release-session-work")
                        }
                    }
                    #endif
                }
                .padding(24).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity)
            }
            .foregroundStyle(tokens.secondary).tint(tokens.primary)
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
            .sheet(item: $backup.picker) { intent in
                CatalogPackagePicker(selected: { backup.picked($0, intent: intent) }, cancelled: backup.pickerCancelled)
            }
            #if DEBUG
            .onChange(of: backup.probe) { backup.consumeTestSelection() }
            #endif
        }
    }
}

#if DEBUG
/// Observes the privacy and presentation owners directly so the saved-input fixture never renders stale state.
private struct SettingsInputFixtureControls: View {
    @ObservedObject var privacy: CatalogPrivacyService
    @ObservedObject var presentation: AppPresentationState
    var body: some View {
        if privacy.pendingCleanup, ProcessInfo.processInfo.arguments.contains("--uitest-presentation-save-retry") {
            Text(presentation.saveFixtureProbe).accessibilityIdentifier("privacy-input-fixture")
            Button("Repair saved-input fixture") { presentation.setSaveObstructionForTest(create: false) }.accessibilityIdentifier("privacy-repair-inputs")
        }
    }
}
#endif
