import SwiftUI
import TallGrassKit

/// The battle screen: the fight happens on your real floor (AR), with a
/// game-style message box, type-coloured move buttons and HP cards on top.
/// Works for CPU and two-phone battles; the controller decides who the
/// opponent is.
struct BattleView: View {
    @Bindable var battle: BattleController
    let myName: String
    let theirName: String
    let onLeave: () -> Void

    @Environment(PackStore.self) private var packs
    @State private var player = BattlePlayer()
    @State private var showingSwitch = false
    @State private var showingLog = false

    var body: some View {
        ZStack {
            BattleArenaView(player: player, packs: packs, mySide: battle.mySide)
                .ignoresSafeArea()

            if !player.arenaPlaced {
                ScanPrompt()
            }

            VStack(spacing: 10) {
                HStack(alignment: .top) {
                    HPCard(combatant: player.display[battle.theirSide], trainer: theirName, showNumbers: false)
                    Spacer()
                    Menu {
                        Button("Battle Log", systemImage: "text.alignleft") { showingLog = true }
                        if !battle.isOver {
                            Button("Forfeit", systemImage: "flag.fill", role: .destructive) { battle.forfeit() }
                        } else {
                            Button("Leave", systemImage: "xmark") { onLeave() }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.headline)
                            .frame(width: 40, height: 40)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                }
                Spacer()
                HStack {
                    Spacer()
                    HPCard(combatant: player.display[battle.mySide], trainer: myName, showNumbers: true)
                }
                bottomPanel
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
        .onAppear { player.sync(battle) }
        .onChange(of: battle.beats.count) { _, _ in player.sync(battle) }
        .onChange(of: battle.myOptions.map(\.choice)) { _, _ in autoContinue() }
        .sheet(isPresented: $showingSwitch) {
            SwitchSheet(team: battle.myTeam, options: battle.myOptions.filter(\.isSwitch)) { choice in
                showingSwitch = false
                battle.choose(choice)
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showingLog) {
            LogSheet(lines: battle.lines)
        }
    }

    // MARK: Bottom panel

    @ViewBuilder
    private var bottomPanel: some View {
        if let error = battle.error {
            MessageBox(text: error, showsNext: false)
        } else if player.isPlaying || (battle.myOptions.isEmpty && !battle.waitingForOpponent && !battle.isOver) {
            MessageBox(text: player.visibleText, showsNext: !player.isTyping)
                .onTapGesture { player.skip() }
        } else if battle.isOver {
            VStack(spacing: 10) {
                MessageBox(text: resultText, showsNext: false)
                Button(action: onLeave) {
                    Text("Done").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
        } else if battle.waitingForOpponent {
            MessageBox(text: "Waiting for \(theirName)…", showsNext: false, spinner: true)
        } else {
            commandPanel
        }
    }

    private var resultText: String {
        switch battle.didIWin {
        case true?: "You defeated \(theirName)!"
        case false?: "\(theirName) won the battle…"
        case nil: "The battle ended in a draw."
        }
    }

    @ViewBuilder
    private var commandPanel: some View {
        let moves = battle.myOptions.filter(\.isMove)
        let switches = battle.myOptions.filter(\.isSwitch)
        VStack(alignment: .leading, spacing: 8) {
            if moves.isEmpty, !switches.isEmpty {
                Text("Choose a Pokémon to send out")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                ForEach(switches) { option in
                    SwitchRow(option: option, team: battle.myTeam) { battle.choose(option.choice) }
                }
            } else {
                Text("What will \(battle.myActiveName ?? "your Pokémon") do?")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(moves) { option in
                        MoveButton(option: option) { battle.choose(option.choice) }
                    }
                }
                if !switches.isEmpty {
                    Button { showingSwitch = true } label: {
                        Label("Switch Pokémon", systemImage: "arrow.triangle.2.circlepath")
                            .font(.subheadline.bold())
                            .frame(maxWidth: .infinity, minHeight: 40)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                }
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.25), lineWidth: 1))
    }

    /// Team preview has one "Start Battle" choice; just take it.
    private func autoContinue() {
        let options = battle.myOptions
        if options.count == 1, case .other = options[0].kind {
            battle.choose(options[0].choice)
        }
    }
}

// MARK: - Pieces

private struct ScanPrompt: View {
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "viewfinder")
                .font(.system(size: 54, weight: .light))
                .scaleEffect(pulse ? 1.08 : 0.95)
            Text("Point at the floor to set up the battle")
                .font(.headline)
            Text("Tap anywhere on the floor later to move it.")
                .font(.caption)
        }
        .foregroundStyle(.white)
        .shadow(radius: 6)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

struct MessageBox: View {
    let text: String
    var showsNext = true
    var spinner = false
    @State private var blink = false

    var body: some View {
        HStack(alignment: .bottom) {
            if spinner { ProgressView().tint(.white) }
            Text(text.isEmpty ? " " : text)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if showsNext {
                Image(systemName: "arrowtriangle.down.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .opacity(blink ? 0.2 : 1)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 0.5).repeatForever()) { blink = true }
                    }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(
            LinearGradient(colors: [Color(red: 0.12, green: 0.14, blue: 0.2), Color(red: 0.06, green: 0.07, blue: 0.1)],
                           startPoint: .top, endPoint: .bottom).opacity(0.9),
            in: RoundedRectangle(cornerRadius: 20)
        )
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.35), lineWidth: 1.5))
        .contentShape(Rectangle())
    }
}

private struct HPCard: View {
    let combatant: BattleController.Combatant?
    let trainer: String
    let showNumbers: Bool

    var body: some View {
        if let c = combatant {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(c.name).font(.headline).lineLimit(1)
                    if c.shiny { Image(systemName: "sparkles").foregroundStyle(.yellow).font(.caption) }
                    Spacer(minLength: 8)
                    Text("Lv. 50").font(.caption.bold()).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text("HP")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(.yellow)
                    HPBar(fraction: c.hpFraction)
                }
                HStack {
                    if let status = c.status { StatusChip(status: status) }
                    if c.fainted { StatusChip(status: "fnt") }
                    Spacer()
                    Text(showNumbers ? "\(c.hp) / \(c.maxHP)" : "\(Int((c.hpFraction * 100).rounded()))%")
                        .font(.caption.monospacedDigit().bold())
                }
            }
            .padding(10)
            .frame(width: 210)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.3), lineWidth: 1))
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }
}

private struct HPBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.black.opacity(0.35))
                Capsule()
                    .fill(color.gradient)
                    .frame(width: max(0, geo.size.width * fraction))
            }
        }
        .frame(height: 8)
        .animation(.easeOut(duration: 0.6), value: fraction)
    }

    private var color: Color {
        fraction > 0.5 ? .green : fraction > 0.2 ? .yellow : .red
    }
}

private struct StatusChip: View {
    let status: String

    var body: some View {
        let (label, color): (String, Color) = switch status {
        case "brn": ("BRN", .orange)
        case "par": ("PAR", .yellow)
        case "psn", "tox": ("PSN", .purple)
        case "slp": ("SLP", .gray)
        case "frz": ("FRZ", .cyan)
        case "fnt": ("FNT", .red)
        default: (status.uppercased(), .gray)
        }
        Text(label)
            .font(.caption2.weight(.heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color, in: Capsule())
    }
}

enum TypeStyle {
    static func color(_ type: String) -> Color {
        let hex: [String: UInt32] = [
            "Normal": 0xA8A77A, "Fire": 0xEE8130, "Water": 0x6390F0, "Electric": 0xF7D02C,
            "Grass": 0x7AC74C, "Ice": 0x96D9D6, "Fighting": 0xC22E28, "Poison": 0xA33EA1,
            "Ground": 0xE2BF65, "Flying": 0xA98FF3, "Psychic": 0xF95587, "Bug": 0xA6B91A,
            "Rock": 0xB6A136, "Ghost": 0x735797, "Dragon": 0x6F35FC, "Dark": 0x705746,
            "Steel": 0xB7B7CE, "Fairy": 0xD685AD,
        ]
        let v = hex[type] ?? 0x888888
        return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255)
    }

    /// Light type colours need dark text to stay readable.
    static func text(_ type: String) -> Color {
        ["Electric", "Ice", "Ground", "Steel", "Normal", "Bug", "Rock", "Grass"].contains(type) ? .black : .white
    }
}

private struct MoveButton: View {
    let option: BattleController.Option
    let action: () -> Void

    var body: some View {
        if case .move(let info, let pp, let maxPP, let effectiveness) = option.kind {
            let type = info?.type ?? "Normal"
            let fg = TypeStyle.text(type)
            let empty = (pp ?? 1) <= 0
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                action()
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 4) {
                        Text(option.label)
                            .font(.system(.headline, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Spacer(minLength: 2)
                        Image(systemName: categoryIcon(info?.category))
                            .font(.caption.bold())
                    }
                    HStack(spacing: 6) {
                        Text(type.uppercased())
                            .font(.caption2.weight(.heavy))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(fg.opacity(0.18), in: Capsule())
                        Spacer(minLength: 2)
                        if let pp, let maxPP {
                            Text("PP \(pp)/\(maxPP)").font(.caption2.monospacedDigit().bold())
                        }
                    }
                    EffectLabel(multiplier: effectiveness, color: fg)
                }
                .foregroundStyle(fg)
                .padding(10)
                .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
                .background(
                    LinearGradient(colors: [TypeStyle.color(type), TypeStyle.color(type).opacity(0.72)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 14)
                )
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.4), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(empty)
            .opacity(empty ? 0.4 : 1)
        }
    }

    private func categoryIcon(_ category: String?) -> String {
        switch category {
        case "Physical": "burst.fill"
        case "Special": "sparkles"
        default: "circle.dotted"
        }
    }
}

private struct EffectLabel: View {
    let multiplier: Double?
    let color: Color

    var body: some View {
        if let m = multiplier {
            let text = m == 0 ? "No effect" : m > 1 ? "Super effective" : m < 1 ? "Not very effective" : ""
            if !text.isEmpty {
                Label(text, systemImage: m > 1 ? "bolt.fill" : m == 0 ? "nosign" : "arrow.down")
                    .font(.caption2.bold())
                    .foregroundStyle(color.opacity(0.9))
            }
        }
    }
}

private struct SwitchRow: View {
    let option: BattleController.Option
    let team: [BattleRequest.SidePokemon]
    let action: () -> Void

    var body: some View {
        let mon = team.first { $0.name == option.label }
        Button(action: action) {
            HStack {
                Text(option.label).font(.headline)
                Spacer()
                if let mon { ConditionText(condition: mon.condition) }
            }
            .padding(12)
            .foregroundStyle(.white)
            .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

private struct ConditionText: View {
    let condition: String

    var body: some View {
        let parts = condition.split(separator: " ")
        let nums = (parts.first ?? "").split(separator: "/").compactMap { Double($0) }
        let fraction = nums.count == 2 && nums[1] > 0 ? nums[0] / nums[1] : 0
        HStack(spacing: 6) {
            if parts.count > 1 { StatusChip(status: String(parts[1])) }
            HPBar(fraction: fraction).frame(width: 70)
            Text(parts.first.map(String.init) ?? "").font(.caption.monospacedDigit())
        }
    }
}

private struct SwitchSheet: View {
    let team: [BattleRequest.SidePokemon]
    let options: [BattleController.Option]
    let onPick: (String) -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(team.enumerated()), id: \.offset) { _, mon in
                    let option = options.first { $0.label == mon.name }
                    Button {
                        if let option { onPick(option.choice) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(mon.name).font(.headline)
                                if mon.active { Text("In battle").font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            ConditionText(condition: mon.condition)
                        }
                    }
                    .disabled(option == nil)
                }
            }
            .navigationTitle("Switch Pokémon")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct LogSheet: View {
    let lines: [String]

    var body: some View {
        NavigationStack {
            List(Array(lines.enumerated()), id: \.offset) { item in
                Text(item.element)
                    .font(item.element.hasPrefix("—") ? .caption.bold() : .body)
                    .foregroundStyle(item.element.hasPrefix("—") ? .secondary : .primary)
            }
            .navigationTitle("Battle Log")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// A CPU battle launched from the home screen.
struct CPUBattleScreen: View {
    let team: [BattleMon]
    let pack: CreaturePack
    let onClose: () -> Void
    @State private var battle = BattleController(mySide: "p1", opponent: .cpu)

    var body: some View {
        BattleView(battle: battle, myName: "You", theirName: "Wild Trainer") {
            battle.finish()
            onClose()
        }
        .task {
            var rng = SeededRandom(seed: UInt64.random(in: .min ... .max), label: "cpu-team")
            let cpuTeam = (0..<max(1, team.count)).compactMap { _ -> BattleMon? in
                guard let species = rng.pick(pack.species) else { return nil }
                return Loadout.roll(for: species, shiny: rng.chance(1.0 / 128), rng: &rng)
            }
            let seed = (0..<4).map { _ in UInt16(truncatingIfNeeded: rng.next()) }
            battle.start(seed: seed, p1: ("You", team), p2: ("Wild Trainer", cpuTeam))
        }
    }
}
