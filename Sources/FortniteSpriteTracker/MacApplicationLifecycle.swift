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

    /// Runs exactly once per window.
    ///
    /// SwiftUI calls `updateNSView` on every re-render of the scene, and this
    /// view sits in the body of a `WindowGroup` that observes the capture
    /// manager — so it re-ran several times a second. The `configuredWindow`
    /// gate was meant to stop that, but four window mutations had drifted above
    /// it, so `styleMask` and `collectionBehavior` were being re-applied on
    /// every one of those renders.
    ///
    /// Each `collectionBehavior` write is a Window Server round trip that makes
    /// WindowManager re-evaluate window ordering. That is cheap most of the
    /// time and expensive at exactly the wrong moment: while the macOS content
    /// sharing picker has a window-picking session open, every re-order makes
    /// WindowManager re-walk the window list deciding which window holds key.
    /// Measured on this machine, window-order changes ran at 2–3 per second
    /// while the picker was up against 0.3 per second otherwise, and the picker
    /// took minutes to accept a click.
    private func configureWhenAttached(_ view: NSView, coordinator: Coordinator) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            guard coordinator.configuredWindow !== window else { return }
            coordinator.configuredWindow = window

            window.styleMask.formUnion([.titled, .closable, .miniaturizable, .resizable])
            var behavior = window.collectionBehavior
            behavior.remove(.fullScreenAuxiliary)
            behavior.insert(.fullScreenPrimary)
            if behavior != window.collectionBehavior {
                window.collectionBehavior = behavior
            }
            window.standardWindowButton(.zoomButton)?.isEnabled = true
            window.standardWindowButton(.zoomButton)?.isHidden = false

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
