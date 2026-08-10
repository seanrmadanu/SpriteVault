import Foundation

enum SpriteRarity: String, Codable, CaseIterable, Sendable {
    case rare = "RARE"
    case epic = "EPIC"
    case legendary = "LEGENDARY"
    case mythic = "MYTHIC"
    case special = "SPECIAL"
}

struct SpriteItem: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let name: String
    let rarity: SpriteRarity
    var owned: Bool
    var mastered: Bool
    var level: Int?

    init(
        name: String,
        rarity: SpriteRarity,
        owned: Bool = false,
        mastered: Bool = false,
        level: Int? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.rarity = rarity
        self.owned = owned
        self.mastered = mastered
        self.level = level
    }

    var imageAssetName: String {
        name
            .folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
