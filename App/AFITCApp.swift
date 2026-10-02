import SwiftUI
import AFITCCore

@main
struct AFITCApp: App {
    @StateObject private var services = AppServices()

    var body: some Scene {
        WindowGroup {
            RootView(services: services)
        }
    }
}
