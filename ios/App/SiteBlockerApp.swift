import SwiftUI

@main
struct SiteBlockerMobileApp: App {
    @StateObject private var store = MobileStore.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Must register before the app finishes launching, or BGTaskScheduler traps.
        MobileStore.registerBackgroundTask()
    }

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(store)
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:     store.onForeground()
            case .background: store.onBackground()
            default:          break
            }
        }
    }
}
