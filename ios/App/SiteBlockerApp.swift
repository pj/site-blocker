import SwiftUI

@main
struct SiteBlockerMobileApp: App {
    @StateObject private var store = MobileStore.shared

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(store)
        }
    }
}
