import Foundation
import CoreGraphics

struct CaptureWindowInfo: Identifiable, Hashable, Sendable {
    let id: CGWindowID
    let applicationName: String
    let title: String
    let width: Int
    let height: Int
    let isLikelyGameWindow: Bool

    var displayName: String {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanTitle.isEmpty || cleanTitle == applicationName {
            return applicationName
        }
        return "\(applicationName) — \(cleanTitle)"
    }

    var sizeText: String {
        "\(width)×\(height)"
    }
}
