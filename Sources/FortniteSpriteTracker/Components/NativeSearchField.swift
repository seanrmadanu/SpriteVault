import SwiftUI
import AppKit

/// Native macOS search field with explicit first-responder handling and a
/// high-contrast dark appearance. The native field is kept because it remains
/// reliable when Sprite Vault uses a hidden/title-bar-light window style.
struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = "Search"

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = ClickToFocusSearchField(frame: .zero)
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchChanged(_:))
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.isEditable = true
        field.isSelectable = true
        field.isEnabled = true
        field.font = .systemFont(ofSize: 14, weight: .medium)
        field.textColor = .white
        field.drawsBackground = true
        field.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.96)
        field.placeholderString = placeholder
        field.bezelStyle = .roundedBezel
        field.controlSize = .large
        field.focusRingType = .none
        field.stringValue = text

        applyPlaceholderStyle(to: field)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text

        // `stringValue` can lag behind the field editor while the user types.
        // Do not overwrite the live editor with an older SwiftUI value.
        if field.currentEditor() == nil, field.stringValue != text {
            field.stringValue = text
        }
        if field.placeholderString != placeholder {
            field.placeholderString = placeholder
            applyPlaceholderStyle(to: field)
        }
        field.textColor = .white
        field.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.96)
    }

    private func applyPlaceholderStyle(to field: NSSearchField) {
        guard let cell = field.cell as? NSSearchFieldCell else { return }
        cell.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: NSFont.systemFont(ofSize: 14, weight: .medium)
            ]
        )
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        @objc func searchChanged(_ sender: NSSearchField) {
            text.wrappedValue = sender.currentEditor()?.string ?? sender.stringValue
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSearchField else { return }
            text.wrappedValue = field.currentEditor()?.string ?? field.stringValue
        }
    }
}

private final class ClickToFocusSearchField: NSSearchField {
    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        if let window {
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }

        super.mouseDown(with: event)

        if let editor = currentEditor() {
            editor.textColor = .white
            window?.makeFirstResponder(editor)
        }
    }
}
