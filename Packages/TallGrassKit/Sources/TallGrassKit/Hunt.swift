import Foundation

/// Settings for one hunt round. Both players in a match use the same config.
public struct HuntConfig: Codable, Hashable, Sendable {
    /// Length of the hunt in seconds.
    public var duration: Double = 180
    /// Maximum team size; the hunt ends early once it's full.
    public var teamSize: Int = 6
    /// Creatures present the moment the hunt starts.
    public var initialSpawns: Int = 4
    /// Upper bound on spawns for the whole round.
    public var totalSpawns: Int = 40
    /// Seconds between later spawns.
    public var spawnInterval: ClosedRange<Double> = 4...9
    public var shinyChance: Double = 1.0 / 128
    /// Multiplier on rare-tier spawn weights (1 = normal; raise for a "lucky" round).
    public var luck: Double = 1

    public init() {}

    func rarityBoost(for rarity: Rarity) -> Double {
        rarity >= .rare ? luck : 1
    }
}

public enum ThrowOutcome: Codable, Hashable, Sendable {
    case caught
    case brokeFree
    case fled
}

/// One player's hunt: which creatures they've thrown at, caught or scared off.
///
/// Time is passed in rather than read from the clock so the rules are easy to
/// test and replay.
public struct HuntSession: Sendable {
    public let config: HuntConfig
    public let seed: UInt64
    public let player: Int
    public let spawns: [Spawn]
    public private(set) var caught: [Spawn] = []
    public private(set) var fled: Set<Int> = []
    public private(set) var attempts: [Int: Int] = [:]
    private var throwCount = 0

    public init(config: HuntConfig, seed: UInt64, player: Int, species: [CreatureSpecies]) {
        self.config = config
        self.seed = seed
        self.player = player
        self.spawns = SpawnPlanner(species: species, config: config).plan(seed: seed, player: player)
    }

    public var isTeamFull: Bool { caught.count >= config.teamSize }

    public func isOver(at time: Double) -> Bool {
        isTeamFull || time >= config.duration
    }

    public func timeRemaining(at time: Double) -> Double {
        max(0, config.duration - time)
    }

    /// Spawns currently in the world at `time` that can still be caught.
    public func visible(at time: Double) -> [Spawn] {
        guard !isOver(at: time) else { return [] }
        let caughtIDs = Set(caught.map(\.id))
        return spawns.filter {
            $0.appearsAt <= time && time < $0.leavesAt
                && !caughtIDs.contains($0.id) && !fled.contains($0.id)
        }
    }

    /// Resolves a throw. `quality` is 0…1 from the throw mechanic (1 = perfect).
    @discardableResult
    public mutating func attemptCatch(spawnID: Int, quality: Double, at time: Double) -> ThrowOutcome? {
        guard let spawn = visible(at: time).first(where: { $0.id == spawnID }) else { return nil }
        throwCount += 1
        var rng = SeededRandom(seed: seed, label: "throw:\(player):\(throwCount)")
        let tries = attempts[spawnID, default: 0]
        attempts[spawnID] = tries + 1

        let chance = CatchModel.chance(rarity: spawn.rarity, quality: quality, previousMisses: tries)
        if rng.chance(chance) {
            caught.append(spawn)
            return .caught
        }
        if rng.chance(spawn.rarity.fleeChancePerMiss) {
            fled.insert(spawnID)
            return .fled
        }
        return .brokeFree
    }
}

public enum CatchModel {
    /// Chance a throw of the given quality catches a creature of this rarity.
    /// Each earlier miss adds a little, so persistence pays off on rare ones.
    public static func chance(rarity: Rarity, quality: Double, previousMisses: Int) -> Double {
        let q = min(1, max(0, quality))
        let throwFactor = 0.35 + 0.65 * q
        let persistence = 1 + 0.1 * Double(min(previousMisses, 5))
        return min(0.98, rarity.baseCatchChance * throwFactor * persistence)
    }
}
