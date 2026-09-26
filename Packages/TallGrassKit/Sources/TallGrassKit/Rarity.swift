import Foundation

/// How rare a species is: controls how often it spawns, how far away and how
/// briefly it appears, and how hard it is to catch.
///
/// Derived from the game's own catch rate plus base stat total, because catch
/// rate alone is too coarse: in Violet 1.0.1, 139 of 476 species share a catch
/// rate of 45 (from starters to pseudo-legendaries).
public enum Rarity: Int, Codable, CaseIterable, Comparable, Sendable {
    case common, uncommon, rare, epic, legendary

    public static func < (a: Rarity, b: Rarity) -> Bool { a.rawValue < b.rawValue }

    public static func classify(catchRate: Int, baseStatTotal: Int, isLegendary: Bool) -> Rarity {
        // Tuned against the 476 Violet 1.0.1 base species:
        // 133 common, 113 uncommon, 143 rare, 44 epic, 43 legendary.
        if isLegendary || catchRate <= 6 { return .legendary }
        if baseStatTotal >= 540 || catchRate <= 25 { return .epic }
        if baseStatTotal >= 480 || (catchRate <= 45 && baseStatTotal >= 420) { return .rare }
        if baseStatTotal >= 380 || catchRate <= 90 { return .uncommon }
        return .common
    }

    public var label: String {
        switch self {
        case .common: "Common"
        case .uncommon: "Uncommon"
        case .rare: "Rare"
        case .epic: "Epic"
        case .legendary: "Legendary"
        }
    }

    /// Relative chance that a spawn is of this tier (before any per-round
    /// tweaks). Sums to 100 so the numbers read as percentages.
    public var spawnWeight: Double {
        switch self {
        case .common: 52
        case .uncommon: 28
        case .rare: 13
        case .epic: 6
        case .legendary: 1
        }
    }

    /// Base chance that a perfect throw catches it on the first try.
    public var baseCatchChance: Double {
        switch self {
        case .common: 0.85
        case .uncommon: 0.65
        case .rare: 0.45
        case .epic: 0.28
        case .legendary: 0.12
        }
    }

    /// Chance it flees after each failed throw.
    public var fleeChancePerMiss: Double {
        switch self {
        case .common: 0.05
        case .uncommon: 0.10
        case .rare: 0.18
        case .epic: 0.25
        case .legendary: 0.35
        }
    }

    /// How far from the player it spawns, in metres. Rarer ones are further
    /// away and more likely to be behind you.
    public var spawnDistance: ClosedRange<Double> {
        switch self {
        case .common: 1.0...3.0
        case .uncommon: 1.5...4.0
        case .rare: 2.5...5.0
        case .epic: 3.0...6.0
        case .legendary: 4.0...7.0
        }
    }

    /// Seconds it stays before wandering off if nobody catches it.
    public var lifetime: ClosedRange<Double> {
        switch self {
        case .common: 40...70
        case .uncommon: 30...55
        case .rare: 22...40
        case .epic: 15...30
        case .legendary: 10...20
        }
    }
}
