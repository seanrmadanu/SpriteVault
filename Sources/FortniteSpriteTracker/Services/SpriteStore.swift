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
    }

    var ownedCount: Int { sprites.filter(\.owned).count }
    var masteredCount: Int { sprites.filter(\.mastered).count }

    var filteredSprites: [SpriteItem] {
        sprites.filter { item in
            let matchesSearch = searchText.isEmpty || item.name.localizedCaseInsensitiveContains(searchText)
            let matchesRarity = selectedRarity == nil || item.rarity == selectedRarity
            let matchesOwned = !showOnlyOwned || item.owned
            let matchesNotOwned = !showOnlyNotOwned || !item.owned
            let matchesMastered = !showOnlyMastered || item.mastered
            return matchesSearch && matchesRarity && matchesOwned && matchesNotOwned && matchesMastered
        }
    }

    func toggleOwned(_ item: SpriteItem) {
        guard let i = sprites.firstIndex(where: { $0.id == item.id }) else { return }
        sprites[i].owned.toggle()
        if !sprites[i].owned { sprites[i].mastered = false }
        recentEvent = .init(name: sprites[i].name, kind: sprites[i].owned ? .owned : .removed)
    }

    func toggleMastered(_ item: SpriteItem) {
        guard let i = sprites.firstIndex(where: { $0.id == item.id }) else { return }
        sprites[i].mastered.toggle()
        if sprites[i].mastered { sprites[i].owned = true }
        recentEvent = .init(name: sprites[i].name, kind: sprites[i].mastered ? .mastered : .owned)
    }

    func applyDetection(name: String, mastered: Bool) {
        guard let i = sprites.firstIndex(where: { normalized($0.name) == normalized(name) }) else { return }
        let becameOwned = !sprites[i].owned
        let becameMastered = mastered && !sprites[i].mastered
        sprites[i].owned = true
        if mastered { sprites[i].mastered = true }
        if becameMastered { recentEvent = .init(name: sprites[i].name, kind: .mastered) }
        else if becameOwned { recentEvent = .init(name: sprites[i].name, kind: .owned) }
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
        sprites = SpriteCatalog.all
        clearFilters()
    }

    private func load() {
        if let data = try? Data(contentsOf: saveURL),
           let saved = try? JSONDecoder().decode([SpriteItem].self, from: data),
           saved.count == SpriteCatalog.all.count {
            sprites = saved
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
}

struct SpriteEvent: Equatable {
    enum Kind { case owned, mastered, removed }
    let name: String
    let kind: Kind
}
