import SwiftUI
import AppKit

@main
struct FortniteSpriteTrackerApp: App {
    @NSApplicationDelegateAdaptor(MacApplicationDelegate.self) private var applicationDelegate
    @StateObject private var store = SpriteStore()
    @StateObject private var liveCapture = LiveCaptureManager()
    @StateObject private var activityStore = ActivityStore()
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true

    var body: some Scene {
        WindowGroup("Sprite Vault", id: "main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(liveCapture)
                .environmentObject(activityStore)
                .frame(minWidth: 980, minHeight: 680)
                .background(WindowConfigurationView())
        }
        .defaultSize(width: 1180, height: 780)

        MenuBarExtra(isInserted: $showMenuBarExtra) {
            SpriteMenuBarView()
                .environmentObject(store)
                .environmentObject(liveCapture)
                .environmentObject(activityStore)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: liveCapture.menuBarSymbol)
                if liveCapture.isHotkeyScanning {
                    Text(liveCapture.coverageText)
                        .monospacedDigit()
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}
