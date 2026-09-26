import Foundation

/// One creature appearing during a hunt. Positions are relative to where the
/// player stood when the hunt started, so they work in any room or park.
public struct Spawn: Codable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var speciesID: String
    public var rarity: Rarity
    public var isShiny: Bool
    /// Seconds after the hunt starts.
    public var appearsAt: Double
    public var lifetime: Double
    public var distance: Double
    /// Degrees clockwise from the direction the player faced at the start.
    public var bearing: Double
    /// Metres above the detected floor (non-zero for flying species).
    public var height: Double

    public var leavesAt: Double { appearsAt + lifetime }
}

/// Builds the whole schedule of spawns for a hunt up front from the round
/// seed. Both players in a match get schedules from the same seed and odds
/// but separate streams, so luck is fair without being identical.
public struct SpawnPlanner: Sendable {
    public var species: [CreatureSpecies]
    public var config: HuntConfig

    public init(species: [CreatureSpecies], config: HuntConfig) {
        self.species = species
        self.config = config
    }

    public func plan(seed: UInt64, player: Int) -> [Spawn] {
        var rng = SeededRandom(seed: seed, label: "spawns:\(player)")
        let byTier = Dictionary(grouping: species, by: \.rarity)
        let tiers = Rarity.allCases.filter { !(byTier[$0]?.isEmpty ?? true) }
        guard !tiers.isEmpty else { return [] }
        let weights = tiers.map { $0.spawnWeight * config.rarityBoost(for: $0) }

        var spawns: [Spawn] = []
        var t = 0.0
        // Seed the room with a few creatures at once, then trickle more in.
        for i in 0..<config.totalSpawns {
            if i >= config.initialSpawns {
                t += config.spawnInterval.lowerBound
                    + rng.unit() * (config.spawnInterval.upperBound - config.spawnInterval.lowerBound)
            }
            if t >= config.duration { break }
            guard let tierIndex = rng.weightedIndex(weights),
                  let pick = rng.pick(byTier[tiers[tierIndex]] ?? []) else { continue }
            let rarity = tiers[tierIndex]
            let distance = Self.lerp(rarity.spawnDistance, rng.unit())
            // Commons favour the front; rarer ones are spread all around.
            let spread = rarity >= .rare ? 360.0 : 200.0
            let bearing = (rng.unit() - 0.5) * spread
            let height = pick.habitat == .air ? 1.0 + rng.unit() * 1.5 : 0
            spawns.append(Spawn(
                id: i, speciesID: pick.id, rarity: rarity,
                isShiny: rng.chance(config.shinyChance),
                appearsAt: t, lifetime: Self.lerp(rarity.lifetime, rng.unit()),
                distance: distance, bearing: bearing, height: height))
        }
        return spawns
    }

    static func lerp(_ range: ClosedRange<Double>, _ t: Double) -> Double {
        range.lowerBound + (range.upperBound - range.lowerBound) * t
    }
}
