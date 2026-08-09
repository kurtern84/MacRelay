import SwiftUI

@main
struct MacRelayiOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = IOSIRCStore()

    var body: some Scene {
        WindowGroup {
            IOSContentView(store: store)
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { store.handleAppBecameActive(true) }
            if phase == .background { store.handleAppBecameActive(false) }
        }
    }
}
