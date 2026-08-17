import Foundation
import SwiftUI

@MainActor
final class SpriteStore: ObservableObject {
    @Published private(set) var profiles: [CollectionProfile] = [] { didSet { save() } }
    @Published private(set) var selectedProfileID = UUID() { didSet { save() } }

    @Published var searchText = ""
    @Published var selectedRarity: SpriteRarity?
    @Published var showOnlyOwned = false
    @Published var showOnlyNotOwned = false
    @Published var showOnlyMastered = false
    @Published var recentEvent: SpriteEvent?

    private let profilesURL: URL
    private let legacySaveURL: URL
    private var hasFinishedLoading = false
    private let saveQueue = DispatchQueue(label: "Sprite profile saving", qos: .utility)

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("FortniteSpriteTracker", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        profilesURL = folder.appendingPathComponent("profiles.json")
        legacySaveURL = folder.appendingPathComponent("sprites.json")

        load()
        hasFinishedLoading = true
        save()
    }

    var selectedProfile: CollectionProfile? {
        profiles.first(where: { $0.id == selectedProfileID })
    }

    var selectedProfileName: String {
        selectedProfile?.name ?? "My Collection"
    }

    var sprites: [SpriteItem] {
        selectedProfile?.sprites ?? []
    }

    var ownedCount: Int {
        selectedProfile?.ownedCount ?? 0
    }

    var masteredCount: Int {
        selectedProfile?.masteredCount ?? 0
    }

    var canDeleteProfile: Bool {
        profiles.count > 1
    }

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

    func profile(withID id: UUID) -> CollectionProfile? {
        profiles.first(where: { $0.id == id })
    }

    func selectProfile(_ id: UUID) {
        guard id != selectedProfileID,
              profiles.contains(where: { $0.id == id }) else { return }

        selectedProfileID = id
        clearFilters()
        recentEvent = nil
    }

    @discardableResult
    func createProfile(named requestedName: String) -> UUID {
        let profile = CollectionProfile(name: uniqueProfileName(requestedName))
        var updated = profiles
        updated.append(profile)
        profiles = updated
        selectedProfileID = profile.id
        clearFilters()
        recentEvent = nil
        return profile.id
    }

    @discardableResult
    func renameProfile(_ id: UUID, to requestedName: String) -> String? {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return nil }
        let finalName = uniqueProfileName(requestedName, excluding: id)

        var updated = profiles
        updated[index].name = finalName
        updated[index].updatedAt = .now
        profiles = updated
        return finalName
    }

    func deleteProfile(_ id: UUID) {
        guard profiles.count > 1,
              let deleteIndex = profiles.firstIndex(where: { $0.id == id }) else { return }

        if selectedProfileID == id {
            let replacementIndex = deleteIndex == 0 ? 1 : 0
            selectedProfileID = profiles[replacementIndex].id
        }

        var updated = profiles
        updated.remove(at: deleteIndex)
        profiles = updated
        clearFilters()
        recentEvent = nil
    }

    func toggleOwned(_ item: SpriteItem) {
        var event: SpriteEvent?
        mutateSelectedProfile { profile in
            guard let index = profile.sprites.firstIndex(where: { $0.id == item.id }) else { return }
            profile.sprites[index].owned.toggle()
            if !profile.sprites[index].owned {
                profile.sprites[index].level = nil
                profile.sprites[index].mastered = false
            }
            event = .init(
                name: profile.sprites[index].name,
                kind: profile.sprites[index].owned ? .owned : .removed
            )
        }
        recentEvent = event
    }

    func toggleMastered(_ item: SpriteItem) {
        var event: SpriteEvent?
        mutateSelectedProfile { profile in
            guard let index = profile.sprites.firstIndex(where: { $0.id == item.id }) else { return }
            profile.sprites[index].mastered.toggle()
            if profile.sprites[index].mastered {
                profile.sprites[index].owned = true
                profile.sprites[index].level = 5
            } else if profile.sprites[index].level == 5 {
                profile.sprites[index].level = nil
            }
            event = .init(
                name: profile.sprites[index].name,
                kind: profile.sprites[index].mastered ? .mastered : .owned
            )
        }
        recentEvent = event
    }

    func setLevel(_ level: Int?, for item: SpriteItem) {
        let validatedLevel = level.flatMap { (1...5).contains($0) ? $0 : nil }
        var event: SpriteEvent?

        mutateSelectedProfile { profile in
            guard let index = profile.sprites.firstIndex(where: { $0.id == item.id }) else { return }
            profile.sprites[index].level = validatedLevel

            if let validatedLevel {
                profile.sprites[index].owned = true
                profile.sprites[index].mastered = validatedLevel == 5
            } else {
                profile.sprites[index].mastered = false
            }

            event = .init(
                name: profile.sprites[index].name,
                kind: profile.sprites[index].mastered ? .mastered : .owned
            )
        }
        recentEvent = event
    }

    @discardableResult
    func applyDetections(
        _ detections: [DetectedSprite],
        replacingExisting: Bool
    ) -> DetectionApplySummary {
        applyDetections(
            detections,
            to: selectedProfileID,
            replacingExisting: replacingExisting
        )
    }

    @discardableResult
    func applyDetections(
        _ detections: [DetectedSprite],
        to profileID: UUID,
        replacingExisting: Bool
    ) -> DetectionApplySummary {
        var changes: [DetectionCollectionChange] = []

        mutateProfile(profileID) { profile in
            if replacingExisting {
                for index in profile.sprites.indices {
                    profile.sprites[index].owned = false
                    profile.sprites[index].mastered = false
                    profile.sprites[index].level = nil
                }
            }

            for detection in detections {
                guard let index = profile.sprites.firstIndex(where: {
                    normalized($0.name) == normalized(detection.name)
                }) else { continue }

                let before = profile.sprites[index]
                profile.sprites[index].owned = detection.owned
                profile.sprites[index].level = detection.level
                profile.sprites[index].mastered = detection.level == 5
                let after = profile.sprites[index]

                guard before.owned != after.owned
                        || before.level != after.level
                        || before.mastered != after.mastered else {
                    continue
                }

                changes.append(
                    DetectionCollectionChange(
                        name: after.name,
                        rarity: after.rarity,
                        previousOwned: before.owned,
                        previousLevel: before.level,
                        newOwned: after.owned,
                        newLevel: after.level,
                        becameMastered: !before.mastered && after.mastered
                    )
                )
            }
        }
        recentEvent = nil

        return DetectionApplySummary(
            scannedNames: detections.map(\.name),
            changes: changes
        )
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

    /// Clears only the currently selected profile.
    func reset() {
        reset(profileID: selectedProfileID)
        clearFilters()
    }

    func reset(profileID: UUID) {
        mutateProfile(profileID) { profile in
            for index in profile.sprites.indices {
                profile.sprites[index].owned = false
                profile.sprites[index].mastered = false
                profile.sprites[index].level = nil
            }
        }
        recentEvent = nil
    }

    private func mutateSelectedProfile(_ mutation: (inout CollectionProfile) -> Void) {
        mutateProfile(selectedProfileID, mutation)
    }

    private func mutateProfile(_ profileID: UUID, _ mutation: (inout CollectionProfile) -> Void) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        var updated = profiles
        mutation(&updated[index])
        updated[index].updatedAt = .now
        profiles = updated
    }

    private func load() {
        if let data = try? Data(contentsOf: profilesURL),
           let archive = try? JSONDecoder().decode(ProfileArchive.self, from: data),
           !archive.profiles.isEmpty {
            profiles = normalizedProfiles(archive.profiles)
            selectedProfileID = profiles.contains(where: { $0.id == archive.selectedProfileID })
                ? archive.selectedProfileID
                : profiles[0].id
            return
        }

        if let data = try? Data(contentsOf: legacySaveURL),
           let savedSprites = try? JSONDecoder().decode([SpriteItem].self, from: data) {
            let migrated = CollectionProfile(
                name: "My Collection",
                sprites: reconciledCollection(savedSprites)
            )
            profiles = [migrated]
            selectedProfileID = migrated.id
            return
        }

        let initial = CollectionProfile(name: "My Collection")
        profiles = [initial]
        selectedProfileID = initial.id
    }

    private func save() {
        guard hasFinishedLoading, !profiles.isEmpty else { return }

        let archive = ProfileArchive(
            version: 1,
            selectedProfileID: selectedProfileID,
            profiles: profiles
        )
        guard let data = try? JSONEncoder().encode(archive) else { return }

        let destination = profilesURL
        saveQueue.async {
            try? data.write(to: destination, options: .atomic)
        }
    }

    private func normalizedProfiles(_ savedProfiles: [CollectionProfile]) -> [CollectionProfile] {
        var usedNames = Set<String>()
        return savedProfiles.map { profile in
            let baseName = cleanedProfileName(profile.name)
            var name = baseName
            var suffix = 2
            while usedNames.contains(name.lowercased()) {
                name = "\(baseName) \(suffix)"
                suffix += 1
            }
            usedNames.insert(name.lowercased())

            return CollectionProfile(
                id: profile.id,
                name: name,
                sprites: reconciledCollection(profile.sprites),
                createdAt: profile.createdAt,
                updatedAt: profile.updatedAt
            )
        }
    }

    private func reconciledCollection(_ saved: [SpriteItem]) -> [SpriteItem] {
        var savedByName: [String: SpriteItem] = [:]
        for item in saved {
            savedByName[normalized(item.name)] = item
        }

        return SpriteCatalog.all.map { catalogItem in
            var item = SpriteItem(name: catalogItem.name, rarity: catalogItem.rarity)
            guard let prior = savedByName[normalized(catalogItem.name)] else { return item }

            let validLevel = prior.level.flatMap { (1...5).contains($0) ? $0 : nil }
            item.level = validLevel
            item.owned = prior.owned || validLevel != nil
            item.mastered = validLevel == 5
            return item
        }
    }

    private func uniqueProfileName(_ requestedName: String, excluding excludedID: UUID? = nil) -> String {
        let baseName = cleanedProfileName(requestedName)
        let existingNames = Set(
            profiles
                .filter { $0.id != excludedID }
                .map { $0.name.lowercased() }
        )

        var candidate = baseName
        var suffix = 2
        while existingNames.contains(candidate.lowercased()) {
            candidate = "\(baseName) \(suffix)"
            suffix += 1
        }
        return candidate
    }

    private func cleanedProfileName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "New Profile" : String(trimmed.prefix(40))
    }

    private func normalized(_ value: String) -> String {
        value.lowercased()
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .filter { $0.isLetter || $0.isNumber }
    }
}

private struct ProfileArchive: Codable {
    let version: Int
    let selectedProfileID: UUID
    let profiles: [CollectionProfile]
}



struct DetectionCollectionChange: Sendable, Equatable {
    let name: String
    let rarity: SpriteRarity
    let previousOwned: Bool
    let previousLevel: Int?
    let newOwned: Bool
    let newLevel: Int?
    let becameMastered: Bool

    var isNewSprite: Bool {
        !previousOwned && newOwned
    }

    var isLevelUp: Bool {
        guard previousOwned,
              let newLevel else { return false }
        return newLevel > (previousLevel ?? 0)
    }
}

struct DetectionApplySummary: Sendable, Equatable {
    let scannedNames: [String]
    let changes: [DetectionCollectionChange]

    var newSprites: [DetectionCollectionChange] {
        changes.filter(\.isNewSprite)
    }

    var masteredSprites: [DetectionCollectionChange] {
        changes.filter { $0.becameMastered && !$0.isNewSprite }
    }

    var levelUps: [DetectionCollectionChange] {
        changes.filter { $0.isLevelUp && !$0.becameMastered && !$0.isNewSprite }
    }

    var updatedExistingCount: Int {
        changes.filter { !$0.isNewSprite }.count
    }
}

struct SpriteEvent: Equatable {
    enum Kind { case owned, mastered, removed }
    let name: String
    let kind: Kind
}
