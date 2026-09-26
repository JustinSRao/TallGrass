import Foundation
import Observation
import TallGrassKit

/// Runs one battle and turns the engine's protocol into state the UI shows.
///
/// Lockstep: every phone in a match runs its own copy of the engine. Each
/// "round" (one request per side) collects both sides' choices, then applies
/// them in a fixed order, p1 then p2, so every copy stays identical. Only
/// choices are sent between phones. Against the CPU, the CPU is simply the
/// other side and chooses locally.
@MainActor @Observable
final class BattleController {
    enum Opponent {
        case cpu
        case remote(send: (_ round: Int, _ side: String, _ choice: String) -> Void)
    }

    struct Option: Identifiable {
        var choice: String
        var label: String
        var detail: String?
        var id: String { choice }
    }

    struct Combatant: Equatable {
        var name: String
        var hp: Int
        var maxHP: Int
        var status: String?
        var fainted: Bool
        var hpFraction: Double { maxHP > 0 ? Double(hp) / Double(maxHP) : 0 }
    }

    /// One thing the 3D stage should animate, in order.
    enum StageEvent: Equatable {
        case switchIn(side: String, species: String)
        case attack(side: String)
        case hit(side: String, effective: Double)
        case faint(side: String)
    }

    let mySide: String
    var theirSide: String { mySide == "p1" ? "p2" : "p1" }

    private(set) var lines: [String] = []
    private(set) var active: [String: Combatant] = [:]
    private(set) var stageEvents: [StageEvent] = []
    private(set) var myOptions: [Option] = []
    private(set) var waitingForOpponent = false
    private(set) var winnerName: String?
    private(set) var isOver = false
    private(set) var error: String?
    private(set) var round = 0

    private let opponent: Opponent
    private var bridge: BattleBridge?
    private var battleID: Int?
    private var requests: [String: BattleRequest] = [:]
    private var pending: [String: String] = [:]
    private var early: [Int: [String: String]] = [:]   // remote choices that arrived before we reached that round
    private var names: [String: String] = [:]
    /// Showdown prints "super effective" before the damage line it belongs to.
    private var pendingEffectiveness: [String: Double] = [:]
    private var cpuRandom: SeededRandom

    init(mySide: String = "p1", opponent: Opponent = .cpu) {
        self.mySide = mySide
        self.opponent = opponent
        cpuRandom = SeededRandom(seed: UInt64.random(in: .min ... .max), label: "cpu")
    }

    var didIWin: Bool? {
        guard isOver else { return nil }
        guard let winnerName, !winnerName.isEmpty else { return nil }
        return winnerName == names[mySide]
    }

    func start(seed: [UInt16], p1: (name: String, team: [BattleMon]), p2: (name: String, team: [BattleMon])) {
        guard bridge == nil else { return }
        names = ["p1": p1.name, "p2": p2.name]
        cpuRandom = SeededRandom(seed: UInt64(seed.reduce(0) { $0 &* 65_536 &+ UInt64($1) }), label: "cpu")
        do {
            let bridge = try BattleBridge()
            self.bridge = bridge
            let update = try bridge.start(seed: seed, p1: p1, p2: p2)
            battleID = update.id
            apply(update)
            beginRound()
        } catch {
            self.error = "\(error)"
        }
    }

    /// The local player picked something.
    func choose(_ choice: String) {
        guard !isOver, pending[mySide] == nil, requests[mySide]?.isActionable == true else { return }
        pending[mySide] = choice
        if case .remote(let send) = opponent { send(round, mySide, choice) }
        resolveIfReady()
    }

    /// A choice arrived from the friend's phone.
    func receive(round: Int, side: String, choice: String) {
        guard side == theirSide else { return }
        if round == self.round {
            pending[side] = choice
            resolveIfReady()
        } else if round > self.round {
            early[round, default: [:]][side] = choice
        }
    }

    func forfeit() {
        guard !isOver else { return }
        isOver = true
        winnerName = names[theirSide]
        lines.append("You left the battle.")
    }

    func opponentLeft() {
        guard !isOver else { return }
        isOver = true
        winnerName = names[mySide]
        lines.append("\(names[theirSide] ?? "Your friend") left the battle.")
    }

    func finish() {
        if let bridge, let battleID { bridge.end(battle: battleID) }
        bridge = nil
    }

    // MARK: Rounds

    private var sidesToAct: [String] {
        ["p1", "p2"].filter { requests[$0]?.isActionable == true }
    }

    private func beginRound() {
        pending = early.removeValue(forKey: round) ?? [:]
        if case .cpu = opponent, requests[theirSide]?.isActionable == true,
           let pick = cpuRandom.pick(requests[theirSide]!.legalChoices) {
            pending[theirSide] = pick
        }
        myOptions = options(for: requests[mySide])
        waitingForOpponent = false
        resolveIfReady()
    }

    private func resolveIfReady() {
        guard let bridge, let battleID, !isOver else { return }
        let needed = sidesToAct
        if needed.isEmpty { return }
        guard needed.allSatisfy({ pending[$0] != nil }) else {
            waitingForOpponent = pending[mySide] != nil
            if pending[mySide] != nil { myOptions = [] }
            return
        }
        do {
            for side in needed {   // fixed order: p1 then p2
                let update = try bridge.choose(battle: battleID, side: side, choice: pending[side]!)
                if let error = update.error {
                    self.error = "Battle desync or illegal move (\(side)): \(error)"
                    return
                }
                apply(update)
            }
        } catch {
            self.error = "\(error)"
            return
        }
        round += 1
        if !isOver { beginRound() }
    }

    // MARK: Engine output

    private func apply(_ update: BattleUpdate) {
        for event in update.events { read(event) }
        requests = update.requests.compactMapValues { $0 }
        if let winner = update.winner {
            isOver = true
            winnerName = winner
            myOptions = []
            waitingForOpponent = false
        }
    }

    private func options(for request: BattleRequest?) -> [Option] {
        guard let request, request.isActionable else { return [] }
        return request.legalChoices.map { choice in
            let parts = choice.split(separator: " ")
            guard parts.count == 2, let n = Int(parts[1]) else {
                return Option(choice: choice, label: request.teamPreview == true ? "Start Battle" : "Continue")
            }
            if parts[0] == "move", let slot = request.active?.first?.moves[safe: n - 1] {
                let pp = slot.pp.flatMap { pp in slot.maxpp.map { "\(pp)/\($0) PP" } }
                return Option(choice: choice, label: slot.move, detail: pp)
            }
            if parts[0] == "switch", let mon = request.side.pokemon[safe: n - 1] {
                return Option(choice: choice, label: "Switch to \(mon.name)", detail: mon.condition)
            }
            return Option(choice: choice, label: choice)
        }
    }

    private func label(_ side: String) -> String { side == mySide ? "" : "Foe " }

    /// Turns Showdown protocol lines into readable text, HP and stage events.
    private func read(_ line: String) {
        let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard f.count > 1 else { return }
        func field(_ i: Int) -> String? { f.indices.contains(i) ? f[i] : nil }
        func side(_ ident: String) -> String { String(ident.prefix(2)) }
        func name(_ ident: String) -> String { ident.components(separatedBy: ": ").last ?? ident }
        func setHP(_ who: String, _ condition: String) {
            let s = side(who)
            var c = active[s] ?? Combatant(name: name(who), hp: 0, maxHP: 0, status: nil, fainted: false)
            let parts = condition.split(separator: " ")
            let hp = parts.first.map(String.init) ?? "0"
            if hp == "0" {
                c.hp = 0
                c.fainted = true
            } else {
                let nums = hp.split(separator: "/").compactMap { Int($0) }
                if nums.count == 2 { c.hp = nums[0]; c.maxHP = nums[1] }
            }
            c.status = parts.count > 1 ? String(parts[1]) : nil
            active[s] = c
        }

        switch f[1] {
        case "switch", "drag":
            guard let who = field(2), let details = field(3), let hp = field(4) else { break }
            let species = details.components(separatedBy: ",").first ?? name(who)
            active[side(who)] = Combatant(name: name(who), hp: 0, maxHP: 0, status: nil, fainted: false)
            setHP(who, hp)
            stageEvents.append(.switchIn(side: side(who), species: species))
            lines.append(side(who) == mySide ? "Go, \(name(who))!" : "\(names[side(who)] ?? "Foe") sent out \(name(who))!")
        case "move":
            guard let who = field(2), let move = field(3) else { break }
            stageEvents.append(.attack(side: side(who)))
            lines.append("\(label(side(who)))\(name(who)) used \(move)!")
        case "-damage":
            guard let who = field(2), let hp = field(3) else { break }
            setHP(who, hp)
            if field(4) == nil {   // direct hits only, not burn/poison/recoil ticks
                stageEvents.append(.hit(side: side(who), effective: pendingEffectiveness.removeValue(forKey: side(who)) ?? 1))
            }
        case "-heal":
            guard let who = field(2), let hp = field(3) else { break }
            setHP(who, hp)
            lines.append("\(label(side(who)))\(name(who)) regained health.")
        case "-status":
            guard let who = field(2), let status = field(3) else { break }
            active[side(who)]?.status = status
            let words = ["brn": "was burned", "par": "is paralyzed", "psn": "was poisoned",
                         "tox": "was badly poisoned", "slp": "fell asleep", "frz": "was frozen solid"]
            lines.append("\(label(side(who)))\(name(who)) \(words[status] ?? "is \(status)")!")
        case "-curestatus":
            guard let who = field(2) else { break }
            active[side(who)]?.status = nil
        case "-boost", "-unboost":
            guard let who = field(2), let stat = field(3), let amount = field(4) else { break }
            let stats = ["atk": "Attack", "def": "Defense", "spa": "Sp. Atk", "spd": "Sp. Def",
                         "spe": "Speed", "accuracy": "accuracy", "evasion": "evasiveness"]
            let dir = f[1] == "-boost" ? "rose" : "fell"
            lines.append("\(label(side(who)))\(name(who))'s \(stats[stat] ?? stat) \(amount == "1" ? "" : "sharply ")\(dir)!")
        case "faint":
            guard let who = field(2) else { break }
            active[side(who)]?.fainted = true
            active[side(who)]?.hp = 0
            stageEvents.append(.faint(side: side(who)))
            lines.append("\(label(side(who)))\(name(who)) fainted!")
        case "-supereffective":
            if let who = field(2) { pendingEffectiveness[side(who)] = 2 }
            lines.append("It's super effective!")
        case "-resisted":
            if let who = field(2) { pendingEffectiveness[side(who)] = 0.5 }
            lines.append("It's not very effective…")
        case "-immune":
            lines.append("It doesn't affect \(field(2).map(name) ?? "the target")…")
        case "-crit": lines.append("A critical hit!")
        case "-miss": lines.append("The attack missed!")
        case "-fail": lines.append("But it failed!")
        case "cant":
            guard let who = field(2), let reason = field(3) else { break }
            let why = ["par": "is paralyzed! It can't move!", "slp": "is fast asleep.", "frz": "is frozen solid!",
                       "flinch": "flinched and couldn't move!", "recharge": "must recharge!"]
            lines.append("\(label(side(who)))\(name(who)) \(why[reason] ?? "can't move!")")
        case "-weather":
            guard let w = field(2), w != "none" else { break }
            if field(3) == nil {
                let text = ["RainDance": "It started to rain!", "SunnyDay": "The sunlight turned harsh!",
                            "Sandstorm": "A sandstorm kicked up!", "Snow": "It started to snow!"]
                if let t = text[w] { lines.append(t) }
            }
        case "turn":
            guard let n = field(2) else { break }
            lines.append("— Turn \(n) —")
        case "win":
            break
        default:
            break
        }
    }

}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
