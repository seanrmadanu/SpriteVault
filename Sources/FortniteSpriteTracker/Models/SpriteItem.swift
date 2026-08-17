import Foundation

enum SpriteRarity: String, Codable, CaseIterable, Sendable {
    case rare = "RARE"
    case epic = "EPIC"
    case legendary = "LEGENDARY"
    case mythic = "MYTHIC"
    case special = "SPECIAL"
}

enum SpriteCollectionStatus: String, Codable, CaseIterable, Sendable {
    case locked
    case collected
    case lost

    var isUnlocked: Bool { self != .locked }
}

struct SpriteItem: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let name: String
    let rarity: SpriteRarity
    var status: SpriteCollectionStatus
    var mastered: Bool
    var level: Int?

    init(
        id: UUID = UUID(),
        name: String,
        rarity: SpriteRarity,
        owned: Bool = false,
        status: SpriteCollectionStatus? = nil,
        mastered: Bool = false,
        level: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.rarity = rarity
        self.status = status ?? (owned ? .collected : .locked)
        self.mastered = mastered || level == 5
        self.level = level
    }

    /// Backward-compatible convenience used throughout the existing UI. A lost
    /// Sprite is still part of the player's unlocked collection and therefore
    /// counts as owned.
    var owned: Bool {
        get { status.isUnlocked }
        set {
            if newValue {
                if status == .locked { status = .collected }
            } else {
                status = .locked
            }
        }
    }

    var isLost: Bool { status == .lost }
    var isLocked: Bool { status == .locked }

    var imageAssetName: String {
        name
            .folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, rarity, status, owned, mastered, level
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        rarity = try container.decode(SpriteRarity.self, forKey: .rarity)
        level = try container.decodeIfPresent(Int.self, forKey: .level)
        mastered = try container.decodeIfPresent(Bool.self, forKey: .mastered) ?? (level == 5)

        if let savedStatus = try container.decodeIfPresent(SpriteCollectionStatus.self, forKey: .status) {
            status = savedStatus
        } else {
            let legacyOwned = try container.decodeIfPresent(Bool.self, forKey: .owned) ?? false
            status = (legacyOwned || level != nil) ? .collected : .locked
        }

        if level == 5 { mastered = true }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(rarity, forKey: .rarity)
        try container.encode(status, forKey: .status)
        // Keep this field for older builds that may read the same profile file.
        try container.encode(owned, forKey: .owned)
        try container.encode(mastered, forKey: .mastered)
        try container.encodeIfPresent(level, forKey: .level)
    }
}
