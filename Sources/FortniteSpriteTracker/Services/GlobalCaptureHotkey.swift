import AppKit
import ApplicationServices

@MainActor
final class GlobalCaptureHotkey {
    static let shared = GlobalCaptureHotkey()

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var handler: (() -> Void)?

    private init() {}

    var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    func requestAccessibilityPermission() -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func install(handler: @escaping () -> Void) {
        self.handler = handler
        guard globalMonitor == nil, localMonitor == nil else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard Self.matchesCaptureShortcut(event) else { return }
            Task { @MainActor in
                self?.handler?()
            }
        }

        // Global monitors intentionally don't receive events sent to this app.
        // The local monitor makes the same shortcut work while Sprite Vault is focused.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard Self.matchesCaptureShortcut(event) else { return event }
            Task { @MainActor in
                self?.handler?()
            }
            return nil
        }
    }

    func uninstall() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        handler = nil
    }

    private static func matchesCaptureShortcut(_ event: NSEvent) -> Bool {
        guard !event.isARepeat,
              event.charactersIgnoringModifiers?.lowercased() == "s" else {
            return false
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let required: NSEvent.ModifierFlags = [.control, .option]
        return flags.contains(required)
            && !flags.contains(.command)
            && !flags.contains(.shift)
    }
}
