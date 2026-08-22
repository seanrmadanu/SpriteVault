import Foundation
import CoreGraphics

enum CaptureSourceMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case systemPicker
    case application
    case window
    case captureDevice

    var id: String { rawValue }

    var title: String {
        switch self {
        case .systemPicker: return "Window Picker"
        case .application: return "Application"
        case .window: return "Specific Window"
        case .captureDevice: return "Capture Device"
        }
    }

    var symbol: String {
        switch self {
        case .systemPicker: return "rectangle.on.rectangle"
        case .application: return "app.fill"
        case .window: return "macwindow"
        case .captureDevice: return "video.fill"
        }
    }
}

struct CaptureApplicationInfo: Identifiable, Hashable, Sendable {
    let id: String
    let applicationName: String
    let bundleIdentifier: String?
    let processID: pid_t
    let windowCount: Int
    let isLikelyGameApplication: Bool

    var displayName: String { applicationName }
}

struct CaptureDeviceInfo: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let manufacturer: String

    var displayName: String {
        let clean = manufacturer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty,
              clean.localizedCaseInsensitiveCompare(name) != .orderedSame else {
            return name
        }
        return "\(name) · \(clean)"
    }
}

struct ResolvedCaptureTarget: Sendable {
    let windowID: CGWindowID
    let applicationName: String
    let windowTitle: String
    let width: Int
    let height: Int
}


struct SystemCaptureSelection: Hashable, Sendable {
    let styleName: String
    let displayName: String
    let detail: String
    let width: Int
    let height: Int

    var sizeText: String { "\(width)×\(height)" }

    /// 6.4 — what the menu bar should show for this source.
    ///
    /// `displayName` already carries the application and window title on
    /// macOS 15.2+ ("OBS — Fullscreen Projector"), so prefixing it with the
    /// style repeats the word "Window". Only fall back to the style prefix when
    /// the name is a placeholder, which is what older systems return.
    var menuBarLabel: String {
        let placeholders = ["Selected Window", "Selected Application", "Selected Screen", "Selected Source"]
        guard !placeholders.contains(displayName) else {
            return "\(styleName) · \(sizeText)"
        }
        return displayName
    }
}
