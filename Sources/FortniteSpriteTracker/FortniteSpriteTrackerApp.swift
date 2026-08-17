import SwiftUI
import AppKit

@main
struct FortniteSpriteTrackerApp: App {
    @NSApplicationDelegateAdaptor(MacApplicationDelegate.self) private var applicationDelegate
    @StateObject private var store = SpriteStore()
    @StateObject private var liveCapture = LiveCaptureManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(liveCapture)
                .frame(minWidth: 980, minHeight: 680)
                .background(WindowConfigurationView())
        }
        .defaultSize(width: 1180, height: 780)
    }
}
