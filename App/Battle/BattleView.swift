import Observation
import SwiftUI
import TallGrassKit

/// Battle against a CPU team rolled from the same pack. The two-phone
/// version reuses this with the CPU replaced by the friend's choices
/// (see PLAN.md, milestone M4).
struct BattleView: View {
    let playerTeam: [BattleMon]
    let pack: CreaturePack
    let onClose: () -> Void

    @State private var battle = BattleController()

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if let error = battle.error {
                    Text(error).foregroundStyle(.red).padding()
                }
                HStack {
                    ActiveCard(title: "CPU", name: battle.activeName["p2"], hp: battle.activeHP["p2"])
                    Spacer()
                    ActiveCard(title: "You", name: battle.activeName["p1"], hp: battle.activeHP["p1"])
                }
                .padding(.horizontal)

                ScrollViewReader { proxy in
                    List(Array(battle.lines.enumerated()), id: \.offset) { item in
                        Text(item.element).font(.callout).id(item.offset)
                    }
                    .listStyle(.plain)
                    .onChange(of: battle.lines.count) { _, count in
                        proxy.scrollTo(count - 1, anchor: .bottom)
                    }
                }

                if let winner = battle.winner {
                    Text(winner.isEmpty ? "It's a tie!" : "\(winner) wins!")
                        .font(.title2.bold())
                } else {
                    ChoiceGrid(options: battle.playerOptions) { battle.choose($0) }
                        .padding(.horizontal)
                }
            }
            .navigationTitle("Battle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Leave", action: onClose)
            }
        }
        .task {
            battle.start(player: playerTeam, pack: pack)
        }
    }
}

private struct ActiveCard: View {
    let title: String
    let name: String?
    let hp: String?

    var body: some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(name ?? "—").font(.headline)
            Text(hp ?? "").font(.caption.monospacedDigit())
        }
        .padding(10)
        .background(.quaternary, in: .rect(cornerRadius: 10))
    }
}

private struct ChoiceGrid: View {
    let options: [BattleController.Option]
    let onPick: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())]) {
            ForEach(options) { option in
                Button(option.label) { onPick(option.choice) }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

@MainActor @Observable
final class BattleController {
    struct Option: Identifiable {
        var choice: String
        var label: String
        var id: String { choice }
    }

    private(set) var lines: [String] = []
    private(set) var activeName: [String: String] = [:]
    private(set) var activeHP: [String: String] = [:]
    private(set) var playerOptions: [Option] = []
    private(set) var winner: String?
    private(set) var error: String?

    private var bridge: BattleBridge?
    private var battleID: Int?
    private var requests: [String: BattleRequest] = [:]
    private var cpu = SeededRandom(seed: UInt64.random(in: .min ... .max), label: "cpu")

    func start(player: [BattleMon], pack: CreaturePack) {
        guard bridge == nil else { return }
        do {
            let bridge = try BattleBridge()
            self.bridge = bridge
            var rng = SeededRandom(seed: UInt64.random(in: .min ... .max), label: "cpu-team")
            let cpuTeam = (0..<max(1, player.count)).compactMap { _ -> BattleMon? in
                guard let species = rng.pick(pack.species) else { return nil }
                return Loadout.roll(for: species, shiny: false, rng: &rng)
            }
            let seed = (0..<4).map { _ in UInt16(truncatingIfNeeded: rng.next()) }
            let update = try bridge.start(seed: seed, p1: ("You", player), p2: ("CPU", cpuTeam))
            battleID = update.id
            apply(update)
        } catch {
            self.error = "\(error)"
        }
    }

    func choose(_ choice: String) {
        guard let bridge, let battleID else { return }
        do {
            apply(try bridge.choose(battle: battleID, side: "p1", choice: choice))
            // The CPU answers whenever it's owed a choice, including forced switches.
            while winner == nil, let request = requests["p2"], request.isActionable,
                  let cpuChoice = cpu.pick(request.legalChoices) {
                apply(try bridge.choose(battle: battleID, side: "p2", choice: cpuChoice))
            }
        } catch {
            self.error = "\(error)"
        }
    }

    private func apply(_ update: BattleUpdate) {
        if let error = update.error { self.error = error }
        for event in update.events { read(event) }
        requests = update.requests.compactMapValues { $0 }
        if let winner = update.winner { self.winner = winner }
        playerOptions = options(for: requests["p1"])
        // Team preview (and any other CPU-first request) is answered right away.
        if let request = requests["p2"], request.isActionable, requests["p1"]?.isActionable != true,
           winner == nil, let bridge, let battleID, let pick = cpu.pick(request.legalChoices),
           let next = try? bridge.choose(battle: battleID, side: "p2", choice: pick) {
            apply(next)
        }
    }

    private func options(for request: BattleRequest?) -> [Option] {
        guard let request, request.isActionable else { return [] }
        return request.legalChoices.map { choice in
            let parts = choice.split(separator: " ")
            guard parts.count == 2, let n = Int(parts[1]) else { return Option(choice: choice, label: "Continue") }
            if parts[0] == "move", let slot = request.active?.first?.moves[safe: n - 1] {
                let pp = slot.pp.map { " (\($0))" } ?? ""
                return Option(choice: choice, label: slot.move + pp)
            }
            if parts[0] == "switch", let mon = request.side.pokemon[safe: n - 1] {
                return Option(choice: choice, label: "→ \(mon.name)")
            }
            return Option(choice: choice, label: choice)
        }
    }

    /// Turns Showdown protocol lines into readable text and tracks the actives.
    private func read(_ line: String) {
        let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard f.count > 1 else { return }
        func side(_ ident: String) -> String { String(ident.prefix(2)) }
        func name(_ ident: String) -> String { ident.components(separatedBy: ": ").last ?? ident }
        func field(_ i: Int) -> String? { f.indices.contains(i) ? f[i] : nil }
        switch f[1] {
        case "switch", "drag":
            guard let who = field(2), let hp = field(4) else { break }
            activeName[side(who)] = name(who)
            activeHP[side(who)] = hp
            lines.append("\(side(who) == "p1" ? "Go" : "CPU sent out") \(name(who))!")
        case "move":
            guard let who = field(2), let move = field(3) else { break }
            lines.append("\(name(who)) used \(move)!")
        case "-damage", "-heal":
            guard let who = field(2), let hp = field(3) else { break }
            activeHP[side(who)] = hp
        case "faint":
            guard let who = field(2) else { break }
            lines.append("\(name(who)) fainted!")
        case "-supereffective": lines.append("It's super effective!")
        case "-resisted": lines.append("It's not very effective…")
        case "-immune": lines.append("It had no effect.")
        case "-crit": lines.append("A critical hit!")
        case "-miss": lines.append("It missed!")
        case "turn":
            guard let n = field(2) else { break }
            lines.append("— Turn \(n) —")
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
