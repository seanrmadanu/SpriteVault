import AppKit
import ApplicationServices

@MainActor
final class GlobalCaptureHotkey {
    static let shared = GlobalCaptureHotkey()

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var startHandler: (() -> Void)?
    private var stopHandler: (() -> Void)?

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

    func install(
        onStart: @escaping () -> Void,
        onStop: @escaping () -> Void
    ) {
        startHandler = onStart
        stopHandler = onStop
        guard globalMonitor == nil, localMonitor == nil else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let action = Self.action(for: event) else { return }
            Task { @MainActor in
                self?.perform(action)
            }
        }

        // Global monitors intentionally don't receive events sent to this app.
        // The local monitor makes the same shortcut work while Sprite Vault is focused.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let action = Self.action(for: event) else { return event }
            Task { @MainActor in
                self?.perform(action)
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
        startHandler = nil
        stopHandler = nil
    }

    private func perform(_ action: HotkeyAction) {
        switch action {
        case .start: startHandler?()
        case .stop: stopHandler?()
        }
    }

    private static func action(for event: NSEvent) -> HotkeyAction? {
        guard !event.isARepeat else { return nil }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let required: NSEvent.ModifierFlags = [.control, .option]
        guard flags.contains(required),
              !flags.contains(.command),
              !flags.contains(.shift) else { return nil }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "s": return .start
        case "x": return .stop
        default: return nil
        }
    }
}

private enum HotkeyAction {
    case start
    case stop
}
