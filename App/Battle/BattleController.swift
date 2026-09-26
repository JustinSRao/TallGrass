import Foundation
import Observation
import TallGrassKit

/// Runs one battle and turns the engine's protocol into "beats" the screen
/// plays one at a time: a line of text, an optional animation, and an HP /
/// status change, so words, animations and HP bars stay in step.
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
        case remote(send: @MainActor (_ round: Int, _ side: String, _ choice: String) -> Void)
    }

    struct Combatant: Equatable {
        var name: String
        var species: String
        var hp: Int
        var maxHP: Int
        var status: String?
        var fainted: Bool
        var shiny: Bool
        var hpFraction: Double { maxHP > 0 ? Double(hp) / Double(maxHP) : 0 }
    }

    /// Something the 3D arena should animate.
    enum StageEvent: Equatable {
        case switchIn(side: String, species: String, shiny: Bool)
        case attack(side: String, category: String)
        case hit(side: String, effective: Double)
        case faint(side: String)
        case celebrate(side: String)
    }

    struct Beat: Identifiable, Equatable {
        let id: Int
        var text: String?
        var event: StageEvent?
        var side: String?
        var combatant: Combatant?
    }

    struct Option: Identifiable {
        enum Kind {
            case move(info: MoveInfo?, pp: Int?, maxPP: Int?, effectiveness: Double?)
            case switchTo(name: String, condition: String)
            case other
        }
        var choice: String
        var label: String
        var kind: Kind
        var id: String { choice }

        var isMove: Bool {
            switch kind {
            case .move: return true
            default: return false
            }
        }

        var isSwitch: Bool {
            switch kind {
            case .switchTo: return true
            default: return false
            }
        }
    }

    let mySide: String
    var theirSide: String { mySide == "p1" ? "p2" : "p1" }

    private(set) var beats: [Beat] = []
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
    private(set) var names: [String: String] = [:]
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

    /// The active creature on my side, for "What will X do?".
    var myActiveName: String? { active[mySide]?.name }

    /// My team as the engine sees it (for the switch sheet).
    var myTeam: [BattleRequest.SidePokemon] { requests[mySide]?.side.pokemon ?? lastTeam }
    private var lastTeam: [BattleRequest.SidePokemon] = []

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
        myOptions = []
        addBeat("You forfeited the battle.")
    }

    func opponentLeft() {
        guard !isOver else { return }
        isOver = true
        winnerName = names[mySide]
        myOptions = []
        addBeat("\(names[theirSide] ?? "Your friend") left the battle.")
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
        if case .cpu = opponent, let request = requests[theirSide], request.isActionable,
           let pick = cpuPick(request) {
            pending[theirSide] = pick
        }
        myOptions = options(for: requests[mySide])
        waitingForOpponent = false
        resolveIfReady()
    }

    /// The CPU prefers damaging moves that hit hard, with a little randomness.
    private func cpuPick(_ request: BattleRequest) -> String? {
        let legal = request.legalChoices
        guard let foe = active[mySide]?.species, let moves = request.active?.first?.moves else {
            return cpuRandom.pick(legal)
        }
        let scored: [(String, Double)] = legal.compactMap { choice in
            let parts = choice.split(separator: " ")
            guard parts.count == 2, parts[0] == "move", let n = Int(parts[1]),
                  let slot = moves[safe: n - 1], let info = bridge?.moveInfo(slot.move) else { return nil }
            let mult = bridge?.effectiveness(move: slot.move, against: foe) ?? 1
            let power = info.category == "Status" ? 35 : Double(max(info.basePower, 40))
            return (choice, power * mult * (0.6 + cpuRandom.unit() * 0.8))
        }
        return scored.max(by: { $0.1 < $1.1 })?.0 ?? cpuRandom.pick(legal)
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
        if let team = requests[mySide]?.side.pokemon { lastTeam = team }
        if let winner = update.winner {
            isOver = true
            winnerName = winner
            myOptions = []
            waitingForOpponent = false
            if let side = names.first(where: { $0.value == winner })?.key {
                addBeat(side == mySide ? "You won the battle!" : "\(winner) won the battle!",
                        event: .celebrate(side: side))
            } else {
                addBeat("The battle ended in a draw.")
            }
        }
    }

    private func options(for request: BattleRequest?) -> [Option] {
        guard let request, request.isActionable else { return [] }
        let foeSpecies = active[theirSide]?.species
        return request.legalChoices.map { choice in
            let parts = choice.split(separator: " ")
            guard parts.count == 2, let n = Int(parts[1]) else {
                return Option(choice: choice, label: request.teamPreview == true ? "Start Battle" : "Continue", kind: .other)
            }
            if parts[0] == "move", let slot = request.active?.first?.moves[safe: n - 1] {
                let info = bridge?.moveInfo(slot.move)
                let mult = foeSpecies.flatMap { bridge?.effectiveness(move: slot.move, against: $0) }
                return Option(choice: choice, label: slot.move,
                              kind: .move(info: info, pp: slot.pp, maxPP: slot.maxpp, effectiveness: mult))
            }
            if parts[0] == "switch", let mon = request.side.pokemon[safe: n - 1] {
                return Option(choice: choice, label: mon.name, kind: .switchTo(name: mon.name, condition: mon.condition))
            }
            return Option(choice: choice, label: choice, kind: .other)
        }
    }

    // MARK: Protocol → beats

    private func addBeat(_ text: String?, event: StageEvent? = nil, side: String? = nil) {
        if let event { stageEvents.append(event) }
        if let text { lines.append(text) }
        beats.append(Beat(id: beats.count, text: text, event: event, side: side,
                          combatant: side.flatMap { active[$0] }))
    }

    private func who(_ side: String, _ name: String) -> String {
        side == mySide ? name : "The opposing \(name)"
    }

    /// Turns one Showdown protocol line into state and (usually) a beat.
    private func read(_ line: String) {
        let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard f.count > 1 else { return }
        func field(_ i: Int) -> String? { f.indices.contains(i) ? f[i] : nil }
        func side(_ ident: String) -> String { String(ident.prefix(2)) }
        func name(_ ident: String) -> String { ident.components(separatedBy: ": ").last ?? ident }
        func from() -> String? {
            f.first(where: { $0.hasPrefix("[from] ") }).map { String($0.dropFirst(7)) }
        }
        func setHP(_ ident: String, _ condition: String) {
            let s = side(ident)
            guard var c = active[s] else { return }
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
            guard let ident = field(2), let details = field(3), let hp = field(4) else { break }
            let s = side(ident)
            let species = details.components(separatedBy: ",").first ?? name(ident)
            let shiny = details.contains("shiny")
            active[s] = Combatant(name: name(ident), species: species, hp: 0, maxHP: 0,
                                  status: nil, fainted: false, shiny: shiny)
            setHP(ident, hp)
            let text = s == mySide ? "Go! \(name(ident))!" : "\(names[s] ?? "Your opponent") sent out \(name(ident))!"
            addBeat(text, event: .switchIn(side: s, species: species, shiny: shiny), side: s)
        case "move":
            guard let ident = field(2), let move = field(3) else { break }
            let category = bridge?.moveInfo(move)?.category ?? "Physical"
            addBeat("\(who(side(ident), name(ident))) used \(move)!",
                    event: .attack(side: side(ident), category: category), side: side(ident))
        case "-damage":
            guard let ident = field(2), let hp = field(3) else { break }
            let s = side(ident)
            setHP(ident, hp)
            if let source = from() {
                let reasons = ["brn": "was hurt by its burn!", "psn": "was hurt by poison!",
                               "tox": "was hurt by poison!", "Recoil": "was damaged by the recoil!",
                               "item: Life Orb": "lost some of its HP!", "Stealth Rock": "was hurt by the pointed stones!",
                               "Sandstorm": "is buffeted by the sandstorm!", "confusion": "hurt itself in its confusion!"]
                addBeat("\(who(s, name(ident))) \(reasons[source] ?? "lost some HP.")", side: s)
            } else {
                let mult = pendingEffectiveness.removeValue(forKey: s) ?? 1
                addBeat(nil, event: .hit(side: s, effective: mult), side: s)
                if mult > 1 { addBeat("It's super effective!") }
                if mult < 1 { addBeat("It's not very effective…") }
            }
        case "-heal":
            guard let ident = field(2), let hp = field(3) else { break }
            setHP(ident, hp)
            let source = from()
            let text = source?.hasPrefix("item: ") == true
                ? "\(who(side(ident), name(ident))) restored a little HP using its \(source!.dropFirst(6))!"
                : "\(who(side(ident), name(ident)))'s HP was restored."
            addBeat(text, side: side(ident))
        case "-status":
            guard let ident = field(2), let status = field(3) else { break }
            active[side(ident)]?.status = status
            let words = ["brn": "was burned!", "par": "is paralyzed! It may be unable to move!",
                         "psn": "was poisoned!", "tox": "was badly poisoned!", "slp": "fell asleep!",
                         "frz": "was frozen solid!"]
            addBeat("\(who(side(ident), name(ident))) \(words[status] ?? "is \(status)!")", side: side(ident))
        case "-curestatus":
            guard let ident = field(2) else { break }
            active[side(ident)]?.status = nil
            addBeat("\(who(side(ident), name(ident))) is no longer \(statusWord(field(3))).", side: side(ident))
        case "-boost", "-unboost":
            guard let ident = field(2), let stat = field(3), let amount = Int(field(4) ?? "") else { break }
            let stats = ["atk": "Attack", "def": "Defense", "spa": "Sp. Atk", "spd": "Sp. Def",
                         "spe": "Speed", "accuracy": "accuracy", "evasion": "evasiveness"]
            let rise = f[1] == "-boost"
            let how = amount >= 3 ? (rise ? "rose drastically" : "severely fell")
                : amount == 2 ? (rise ? "rose sharply" : "harshly fell")
                : amount == 0 ? (rise ? "won't go any higher" : "won't go any lower")
                : (rise ? "rose" : "fell")
            addBeat("\(who(side(ident), name(ident)))'s \(stats[stat] ?? stat) \(how)!")
        case "faint":
            guard let ident = field(2) else { break }
            active[side(ident)]?.fainted = true
            active[side(ident)]?.hp = 0
            addBeat("\(who(side(ident), name(ident))) fainted!", event: .faint(side: side(ident)), side: side(ident))
        case "-supereffective":
            if let ident = field(2) { pendingEffectiveness[side(ident)] = 2 }
        case "-resisted":
            if let ident = field(2) { pendingEffectiveness[side(ident)] = 0.5 }
        case "-immune":
            addBeat("It doesn't affect \(field(2).map { who(side($0), name($0)) } ?? "the target")…")
        case "-crit":
            addBeat("A critical hit!")
        case "-miss":
            if let target = field(3), !target.isEmpty {
                addBeat("\(who(side(target), name(target))) avoided the attack!")
            } else {
                addBeat("The attack missed!")
            }
        case "-fail":
            addBeat("But it failed!")
        case "-ability":
            guard let ident = field(2), let ability = field(3) else { break }
            addBeat("[\(who(side(ident), name(ident)))'s \(ability)]")
        case "-start":
            guard let ident = field(2), let effect = field(3) else { break }
            if effect == "confusion" { addBeat("\(who(side(ident), name(ident))) became confused!") }
        case "cant":
            guard let ident = field(2), let reason = field(3) else { break }
            let why = ["par": "is paralyzed! It can't move!", "slp": "is fast asleep.",
                       "frz": "is frozen solid!", "flinch": "flinched and couldn't move!",
                       "recharge": "must recharge!"]
            addBeat("\(who(side(ident), name(ident))) \(why[reason] ?? "can't move!")")
        case "-weather":
            guard let weather = field(2) else { break }
            if f.contains("[upkeep]") { break }
            let text = ["RainDance": "It started to rain!", "SunnyDay": "The sunlight turned harsh!",
                        "Sandstorm": "A sandstorm kicked up!", "Snow": "It started to snow!",
                        "none": "The weather cleared up."]
            if let t = text[weather] { addBeat(t) }
        case "turn":
            if let n = field(2) { lines.append("— Turn \(n) —") }
        default:
            break
        }
    }

    private func statusWord(_ status: String?) -> String {
        ["brn": "burned", "par": "paralyzed", "psn": "poisoned", "tox": "poisoned",
         "slp": "asleep", "frz": "frozen"][status ?? ""] ?? "affected"
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
