import SwiftUI

struct SettingsView: View {
    @ObservedObject var services: AppServices
    @ObservedObject var backup: CatalogBackupService
    @Environment(\.tokens) private var tokens
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.l) {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                        Text("Your photos stay on your drive.").font(.headline)
                        Text("JPEG previews and face detection run locally. Catalog and previews are private app data; your originals remain on the selected drive.")
                            .foregroundStyle(tokens.textSecondary)
                        Label(services.selectedFolder == nil ? "No source folder selected" : "Original source folder selected",
                              systemImage: "externaldrive")
                            .font(.subheadline.weight(.semibold))
                            .accessibilityIdentifier("backup-source-state")
                    }.card()
                    BackupSettingsSection(services: services, backup: backup)
                    PrivacySettingsActions(services: services)
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
                    // Destructive group last, apart from everything routine.
                    CatalogDeletionSection(services: services)
                }
                .padding(DesignTokens.Spacing.l).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity)
            }
            .background(tokens.background).tint(tokens.primary)
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
