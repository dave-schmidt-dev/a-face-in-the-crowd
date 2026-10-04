import SwiftUI
import AFITCCore

@main
struct AFITCApp: App {
    @UIApplicationDelegateAdaptor(ProtectedDataDelegate.self) private var protectedDelegate
    @StateObject private var services = AppServices()

    var body: some Scene {
        WindowGroup {
            RootView(services: services)
                .overlay(alignment: .bottom) {
                    if services.protection.admitsWork, !services.canStart, !services.isQuiescingCatalog, services.setupError != nil {
                        Button("Retry opening catalog", action: services.retryCatalogStartup)
                            .buttonStyle(.bordered).padding()
                            .accessibilityIdentifier("retry-catalog-startup")
                    }
                }
        }
    }
}
