import Foundation

struct CollectionProfile: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var sprites: [SpriteItem]
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        sprites: [SpriteItem] = SpriteCatalog.blankCollection(),
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.sprites = sprites
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var ownedCount: Int {
        sprites.filter(\.owned).count
    }

    var masteredCount: Int {
        sprites.filter { $0.level == 5 }.count
    }
}
