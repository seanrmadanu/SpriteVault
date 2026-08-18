import SwiftUI
import AppKit

/// Swift Package executables do not always activate like a bundled macOS app
/// when Xcode launches them. Promoting the process to a regular application is
/// what lets its windows become key and receive keyboard input.
final class MacApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async {
            let application = NSApplication.shared
            application.activate(ignoringOtherApps: true)
            application.windows.first(where: \.canBecomeKey)?.makeKeyAndOrderFront(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // During development, closing the main Sprite Vault window should fully
        // terminate the process. This immediately tears down ScreenCaptureKit /
        // camera sessions instead of leaving the menu-bar companion alive.
        //
        // macOS privacy grants themselves are managed by TCC and intentionally
        // persist after an app quits; the app cannot revoke those grants through
        // a supported public API.
        true
    }
}

/// Configures the exact NSWindow created for this SwiftUI scene. Keeping this
/// separate from the app delegate avoids a launch-order race where the delegate
/// runs before SwiftUI has created its first window.
struct WindowConfigurationView: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        configureWhenAttached(view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        configureWhenAttached(view, coordinator: context.coordinator)
    }

    private func configureWhenAttached(_ view: NSView, coordinator: Coordinator) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }

            window.styleMask.formUnion([.titled, .closable, .miniaturizable, .resizable])
            window.collectionBehavior.remove(.fullScreenAuxiliary)
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.standardWindowButton(.zoomButton)?.isEnabled = true
            window.standardWindowButton(.zoomButton)?.isHidden = false

            guard coordinator.configuredWindow !== window else { return }
            coordinator.configuredWindow = window

            let application = NSApplication.shared
            application.setActivationPolicy(.regular)
            application.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    final class Coordinator {
        weak var configuredWindow: NSWindow?
    }
}
