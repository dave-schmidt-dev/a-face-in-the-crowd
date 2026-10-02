import SwiftUI
import AFITCCore

struct StatusView: View {
    @ObservedObject var services: AppServices
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(sourceMessage, systemImage: "externaldrive")
                .accessibilityIdentifier("source-status")
            if services.isRestoringSource {
                ProgressView("Restoring source folder permission").accessibilityIdentifier("restoring-source")
            }
            if services.isScanning {
                ProgressView(services.progress.phase == .cancelling ? "Cancellation requested" : (services.progress.message ?? "Discovering JPEGs"))
                Button(services.progress.phase == .cancelling ? "Cancellation requested" : "Cancel scan", action: services.cancelScan).frame(minHeight: 44)
                    .accessibilityIdentifier("cancel-scan").disabled(services.progress.phase == .cancelling)
            }
            if services.progress.phase != .ready {
                Text("Discovered \(services.progress.discovered) · Processed \(services.progress.processed) · Skipped \(services.progress.skipped) · Failed \(services.progress.failed)")
                    .accessibilityIdentifier("scan-counts")
                Text(services.progress.enumerationFinished ? "Discovery complete" : "Total unknown until discovery completes")
                Text(services.progress.phase.rawValue.capitalized).accessibilityIdentifier("scan-phase")
            }
            if let message = services.progress.message { Text(message) }
            if let error = services.setupError { Text(error).accessibilityIdentifier("setup-error") }
        }.font(.subheadline).accessibilityElement(children: .contain)
    }
    private var sourceMessage: String {
        if services.isScanning { return "Checking selected folder · read only" }
        if services.selectedFolder != nil { return "Folder selected · cached last verified previews" }
        if services.progress.phase != .ready { return "Source access not active · cached previews" }
        return "No folder selected"
    }

}
