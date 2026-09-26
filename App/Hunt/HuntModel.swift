import Foundation
import Observation
import TallGrassKit
import UIKit

/// Drives one hunt: the clock, throws, and rolling a battle loadout for each
/// catch. The AR view reads `visible`, reports throws via `resolveThrow`, and
/// publishes where off-screen creatures are via `indicators`.
@MainActor @Observable
final class HuntModel: Identifiable {
    struct Indicator: Identifiable, Equatable {
        var id: Int
        /// Screen-edge direction, radians (0 = right, π/2 = down).
        var angle: Double
        var rarity: Rarity
    }

    let id = UUID()
    private(set) var session: HuntSession
    private(set) var team: [BattleMon] = []
    private(set) var message: String?
    private(set) var startDate: Date?
    private(set) var now = Date()
    var indicators: [Indicator] = []
    private let speciesByID: [String: CreatureSpecies]
    private var messageSerial = 0

    init(pack: CreaturePack, seed: UInt64, player: Int, config: HuntConfig = HuntConfig()) {
        session = HuntSession(config: config, seed: seed, player: player, species: pack.species)
        speciesByID = Dictionary(pack.species.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    var elapsed: Double { startDate.map { max(0, now.timeIntervalSince($0)) } ?? 0 }
    var timeRemaining: Double { session.timeRemaining(at: elapsed) }
    var hasStarted: Bool { startDate.map { now >= $0 } ?? false }
    var isOver: Bool { hasStarted && session.isOver(at: elapsed) }
    var visible: [Spawn] { hasStarted ? session.visible(at: elapsed) : [] }
    /// Seconds until a scheduled start (two-player countdown), else 0.
    var countdown: Double { startDate.map { max(0, $0.timeIntervalSince(now)) } ?? 0 }

    /// Starts now, or at a shared moment so two phones' clocks line up.
    func start(at date: Date = Date()) {
        if startDate == nil { startDate = date }
    }

    func tick() {
        now = Date()
    }

    func species(for spawn: Spawn) -> CreatureSpecies? {
        speciesByID[spawn.speciesID]
    }

    /// Resolves a throw that reached `spawnID`. `quality` is 0…1. The AR view
    /// animates the returned outcome.
    func resolveThrow(spawnID: Int, quality: Double) -> ThrowOutcome? {
        guard let spawn = visible.first(where: { $0.id == spawnID }),
              let outcome = session.attemptCatch(spawnID: spawnID, quality: quality, at: elapsed) else { return nil }
        if outcome == .caught, let species = species(for: spawn) {
            // Recorded immediately so the team is right even if time runs out
            // while the capture animation is still playing.
            var rng = SeededRandom(seed: session.seed, label: "loadout:\(session.player):\(spawn.id)")
            team.append(Loadout.roll(for: species, shiny: spawn.isShiny, rng: &rng))
        }
        return outcome
    }

    /// Called by the AR view once the capture animation has played out, so
    /// the message and haptics match what the player sees.
    func announce(_ outcome: ThrowOutcome, spawn: Spawn, quality: Double) {
        guard let species = species(for: spawn) else { return }
        let aim = quality > 0.85 ? "Excellent throw! " : quality > 0.6 ? "Great throw! " : quality > 0.35 ? "Nice throw! " : ""
        switch outcome {
        case .caught:
            show("\(aim)Caught \(spawn.isShiny ? "✨shiny " : "")\(species.name)! (\(spawn.rarity.label))")
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .brokeFree:
            show("\(aim)\(species.name) broke free!")
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .fled:
            show("\(species.name) ran away…")
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    func missed() {
        show("Missed!")
    }

    private func show(_ text: String) {
        message = text
        messageSerial += 1
        let serial = messageSerial
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            if self.messageSerial == serial { self.message = nil }
        }
    }
}
