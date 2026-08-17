import Foundation

enum ActivityKind: String, Codable, Sendable {
    case scanStarted
    case scanCompleted
    case scanStopped
    case newSprite
    case levelUp
    case mastered
    case lost
    case error

    var symbol: String {
        switch self {
        case .scanStarted: return "dot.radiowaves.left.and.right"
        case .scanCompleted: return "checkmark.circle.fill"
        case .scanStopped: return "stop.circle.fill"
        case .newSprite: return "sparkles"
        case .levelUp: return "arrow.up.circle.fill"
        case .mastered: return "crown.fill"
        case .lost: return "clock.arrow.circlepath"
        case .error: return "exclamationmark.triangle.fill"
        }
    }
}

struct ScanChangeSummary: Codable, Hashable, Sendable {
    var newSprites: [String] = []
    var levelUps: [String] = []
    var mastered: [String] = []
    var lost: [String] = []

    var totalChanges: Int {
        newSprites.count + levelUps.count + mastered.count + lost.count
    }
}

struct ActivityEvent: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let date: Date
    let kind: ActivityKind
    let title: String
    let message: String
    let profileID: UUID?
    let profileName: String?
    let spriteName: String?
    let sessionID: UUID?
    let summary: ScanChangeSummary?
    var isRead: Bool

    init(
        id: UUID = UUID(),
        date: Date = .now,
        kind: ActivityKind,
        title: String,
        message: String,
        profileID: UUID? = nil,
        profileName: String? = nil,
        spriteName: String? = nil,
        sessionID: UUID? = nil,
        summary: ScanChangeSummary? = nil,
        isRead: Bool = false
    ) {
        self.id = id
        self.date = date
        self.kind = kind
        self.title = title
        self.message = message
        self.profileID = profileID
        self.profileName = profileName
        self.spriteName = spriteName
        self.sessionID = sessionID
        self.summary = summary
        self.isRead = isRead
    }
}
