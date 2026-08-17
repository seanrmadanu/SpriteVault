import Foundation
import CoreGraphics

enum CaptureSourceMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case application
    case window
    case captureDevice

    var id: String { rawValue }

    var title: String {
        switch self {
        case .application: return "Application"
        case .window: return "Specific Window"
        case .captureDevice: return "Capture Device"
        }
    }

    var symbol: String {
        switch self {
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
