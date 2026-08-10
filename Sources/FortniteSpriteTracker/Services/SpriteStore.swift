import Foundation
import SwiftUI

@MainActor
final class SpriteStore: ObservableObject {
    @Published var sprites: [SpriteItem] = [] { didSet { save() } }
    @Published var searchText = ""
    @Published var selectedRarity: SpriteRarity?
    @Published var showOnlyOwned = false
    @Published var showOnlyNotOwned = false
    @Published var showOnlyMastered = false
    @Published var recentEvent: SpriteEvent?

    private let saveURL: URL
    private var hasFinishedLoading = false
    private let saveQueue = DispatchQueue(label: "Sprite progress saving", qos: .utility)

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("FortniteSpriteTracker", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        saveURL = folder.appendingPathComponent("sprites.json")
        load()
        hasFinishedLoading = true
        save()
    }

    var ownedCount: Int { sprites.filter(\.owned).count }
    var masteredCount: Int { sprites.filter { $0.level == 5 }.count }

    var filteredSprites: [SpriteItem] {
        sprites.filter { item in
            let matchesSearch = searchText.isEmpty || item.name.localizedCaseInsensitiveContains(searchText)
            let matchesRarity = selectedRarity == nil || item.rarity == selectedRarity
            let matchesOwned = !showOnlyOwned || item.owned
            let matchesNotOwned = !showOnlyNotOwned || !item.owned
            let matchesMastered = !showOnlyMastered || item.level == 5
            return matchesSearch && matchesRarity && matchesOwned && matchesNotOwned && matchesMastered
        }
    }

    func toggleOwned(_ item: SpriteItem) {
        guard let i = sprites.firstIndex(where: { $0.id == item.id }) else { return }
        sprites[i].owned.toggle()
        if !sprites[i].owned {
            sprites[i].level = nil
            sprites[i].mastered = false
        }
        recentEvent = .init(name: sprites[i].name, kind: sprites[i].owned ? .owned : .removed)
    }

    func toggleMastered(_ item: SpriteItem) {
        guard let i = sprites.firstIndex(where: { $0.id == item.id }) else { return }
        sprites[i].mastered.toggle()
        if sprites[i].mastered {
            sprites[i].owned = true
            sprites[i].level = 5
        } else if sprites[i].level == 5 {
            sprites[i].level = nil
        }
        recentEvent = .init(name: sprites[i].name, kind: sprites[i].mastered ? .mastered : .owned)
    }

    func setLevel(_ level: Int?, for item: SpriteItem) {
        guard let i = sprites.firstIndex(where: { $0.id == item.id }) else { return }
        let validatedLevel = level.flatMap { (1...5).contains($0) ? $0 : nil }
        sprites[i].level = validatedLevel

        if let validatedLevel {
            sprites[i].owned = true
            sprites[i].mastered = validatedLevel == 5
        } else {
            sprites[i].mastered = false
        }

        recentEvent = .init(
            name: sprites[i].name,
            kind: sprites[i].mastered ? .mastered : .owned
        )
    }

    func applyDetections(_ detections: [DetectedSprite], replacingExisting: Bool) {
        var updated = sprites

        if replacingExisting {
            for index in updated.indices {
                updated[index].owned = false
                updated[index].mastered = false
                updated[index].level = nil
            }
        }

        for detection in detections {
            guard let index = updated.firstIndex(where: {
                normalized($0.name) == normalized(detection.name)
            }) else { continue }

            updated[index].owned = detection.owned
            updated[index].level = detection.level
            updated[index].mastered = detection.level == 5
        }

        sprites = updated
        recentEvent = nil
    }

    func setOwnedFilter(_ enabled: Bool) {
        showOnlyOwned = enabled
        if enabled {
            showOnlyNotOwned = false
        }
    }

    func setNotOwnedFilter(_ enabled: Bool) {
        showOnlyNotOwned = enabled
        if enabled {
            showOnlyOwned = false
            showOnlyMastered = false
        }
    }

    func setMasteredFilter(_ enabled: Bool) {
        showOnlyMastered = enabled
        if enabled {
            showOnlyNotOwned = false
        }
    }

    func clearFilters() {
        searchText = ""
        selectedRarity = nil
        showOnlyOwned = false
        showOnlyNotOwned = false
        showOnlyMastered = false
    }

    func reset() {
        var cleared = sprites
        for index in cleared.indices {
            cleared[index].owned = false
            cleared[index].mastered = false
            cleared[index].level = nil
        }
        sprites = cleared
        clearFilters()
        recentEvent = nil
    }

    private func load() {
        if let data = try? Data(contentsOf: saveURL),
           let saved = try? JSONDecoder().decode([SpriteItem].self, from: data),
           saved.count == SpriteCatalog.all.count {
            sprites = saved.map(normalizedState)
        } else {
            sprites = SpriteCatalog.all
        }
    }

    private func save() {
        guard hasFinishedLoading,
              !sprites.isEmpty,
              let data = try? JSONEncoder().encode(sprites) else { return }

        let destination = saveURL
        saveQueue.async {
            try? data.write(to: destination, options: .atomic)
        }
    }

    private func normalized(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: ".", with: "").replacingOccurrences(of: " ", with: "")
    }

    private func normalizedState(_ saved: SpriteItem) -> SpriteItem {
        var item = saved
        if let level = item.level, (1...5).contains(level) {
            item.owned = true
            item.mastered = level == 5
        } else {
            item.level = nil
            item.mastered = false
        }
        return item
    }
}

struct SpriteEvent: Equatable {
    enum Kind { case owned, mastered, removed }
    let name: String
    let kind: Kind
}
