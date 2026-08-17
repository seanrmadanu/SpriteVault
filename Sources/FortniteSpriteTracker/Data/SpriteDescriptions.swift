import Foundation

extension SpriteItem {
    var baseSpriteName: String {
        let prefixes = ["Holofoil ", "Galaxy ", "Gummy ", "Quack ", "Gold ", "Cube ", "Gem "]
        for prefix in prefixes where name.hasPrefix(prefix) {
            return String(name.dropFirst(prefix.count))
        }
        return name
    }

    var variantName: String? {
        let variants = ["Holofoil", "Galaxy", "Gummy", "Quack", "Gold", "Cube", "Gem"]
        return variants.first(where: { name.hasPrefix("\($0) ") })
    }

    var gameplayDescription: String {
        SpriteDescriptions.abilityByBaseName[baseSpriteName]
            ?? "A collectible Fortnite Sprite. Track its ownership, level, and mastery in your vault."
    }

    var variantBonusDescription: String? {
        guard let variantName else { return nil }
        return SpriteDescriptions.variantBonus[variantName]
    }
}

enum SpriteDescriptions {
    // Short paraphrased gameplay summaries. Variant Sprites inherit the base
    // Sprite ability and can display an additional variant perk when known.
    static let abilityByBaseName: [String: String] = [
        "John Wick": "Knocking an opponent reveals nearby enemies for a short time; the mark lasts longer as the Sprite levels up.",
        "Batman": "Lets you launch upward and redeploy with the Bat Cape for extra mobility.",
        "Water": "Restores shields while you stand in water, with stronger restoration at higher levels.",
        "Earth": "Gives opened chests a chance to contain extra rare loot; the chance improves with each level.",
        "Fire": "Triggers a fiery burst after you deal enough damage to an enemy; higher levels reduce the damage needed.",
        "Duck": "Emoting or Jamming restores shields, and the restoration improves as the Sprite levels up.",
        "Ghost": "Reloading briefly cloaks you. Higher levels keep the cloak active for longer.",
        "Dream": "Awards increasingly valuable random loot as it levels, culminating in a large high-tier reward at max level.",
        "Demon": "Eliminations siphon health and shields back to you, with more healing at higher levels.",
        "Punk": "A deliberately mysterious Sprite whose effect may be more than it first appears.",
        "King": "Adds bonus Pickaxe damage, with a much larger damage boost at higher levels.",
        "Vini Jr.": "Sprinting powers up a destructive slide; slide-kicking enemies also boosts fire rate and reload speed.",
        "Burnt Peanut": "Eliminations can generate extra high-tier loot, and the bonus-loot chance improves as it levels.",
        "Zero Point": "Using a self-heal can create a temporary Shield Bubble Jr.; higher levels keep it active longer.",
        "Fishy": "Greatly improves swim speed and briefly boosts movement speed after taking damage.",
        "Striker": "Mantling, hurdling, or wall-scrambling grants Overdrive; higher levels extend its duration.",
        "Aura": "Dealing enough enemy damage grants a Shock Rock charge, with less damage required at higher levels.",
        "Boss": "Raises your maximum health and shields, with a larger increase at each level.",
        "Grim": "Enemies who damage you become marked for a short time; the mark lasts longer as the Sprite levels up.",
        "Air": "Improves sprint speed and jump height while preventing fall damage; jump power grows with level.",
        "Seven": "Shows enemy foot trails to your squad, with trails remaining visible longer at higher levels.",
        "Ironmouse": "When your health is low, it regenerates health over time while granting cloak and low gravity.",
        "Pollo": "After an elimination, you and nearby squadmates regenerate shields for a duration that grows with level.",
        "Llama": "Opening ammo boxes can upgrade a weapon, with the upgrade chance increasing at higher levels.",
        "Peely": "Pings players carrying rare Sprites nearby while also revealing you on the map; the ping radius grows with level."
    ]

    static let variantBonus: [String: String] = [
        "Gold": "Variant perk: bonus XP from eliminations.",
        "Galaxy": "Variant perk: collect more ammo from world pickups.",
        "Gem": "Variant perk: reduced fall damage.",
        "Holofoil": "Variant perk: your squad has an extra chance to find rare Sprite variants from chests."
    ]
}
