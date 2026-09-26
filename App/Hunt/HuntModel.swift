import Foundation
import Observation
import TallGrassKit

/// Drives one hunt: the clock, throws, and rolling a battle loadout for each
/// catch. The AR view reads `visible` and reports taps back via `throwAt`.
@MainActor @Observable
final class HuntModel: Identifiable {
    let id = UUID()
    private(set) var session: HuntSession
    private(set) var team: [BattleMon] = []
    private(set) var message: String?
    private(set) var startDate: Date?
    private(set) var now = Date()
    private let speciesByID: [String: CreatureSpecies]

    init(pack: CreaturePack, seed: UInt64, player: Int, config: HuntConfig = HuntConfig()) {
        session = HuntSession(config: config, seed: seed, player: player, species: pack.species)
        speciesByID = Dictionary(pack.species.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    var elapsed: Double { startDate.map { now.timeIntervalSince($0) } ?? 0 }
    var timeRemaining: Double { session.timeRemaining(at: elapsed) }
    var isOver: Bool { startDate != nil && session.isOver(at: elapsed) }
    var visible: [Spawn] { startDate == nil ? [] : session.visible(at: elapsed) }

    func start() {
        if startDate == nil { startDate = Date() }
    }

    func tick() {
        now = Date()
    }

    func species(for spawn: Spawn) -> CreatureSpecies? {
        speciesByID[spawn.speciesID]
    }

    /// `quality` is 0…1: how well-aimed the throw was.
    func throwAt(spawnID: Int, quality: Double) {
        guard let spawn = visible.first(where: { $0.id == spawnID }),
              let outcome = session.attemptCatch(spawnID: spawnID, quality: quality, at: elapsed),
              let species = species(for: spawn) else { return }
        switch outcome {
        case .caught:
            var rng = SeededRandom(seed: session.seed, label: "loadout:\(session.player):\(spawn.id)")
            team.append(Loadout.roll(for: species, shiny: spawn.isShiny, rng: &rng))
            message = "Caught \(spawn.isShiny ? "shiny " : "")\(species.name)! (\(spawn.rarity.label))"
        case .brokeFree:
            message = "\(species.name) broke free!"
        case .fled:
            message = "\(species.name) ran away…"
        }
    }
}
