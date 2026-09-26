import SwiftUI
import TallGrassKit

/// The battle screen: a 3D stage with both active creatures, HP bars, the
/// battle log, and your move buttons. Works for CPU and two-phone battles;
/// the controller decides who the opponent is.
struct BattleView: View {
    @Bindable var battle: BattleController
    let myName: String
    let theirName: String
    let onLeave: () -> Void

    @Environment(PackStore.self) private var packs

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                BattleStageView(battle: battle, packs: packs)
                    .frame(height: 300)
                HStack(alignment: .top) {
                    HPCard(title: theirName, combatant: battle.active[battle.theirSide])
                    Spacer()
                }
                .padding(10)
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        HPCard(title: myName, combatant: battle.active[battle.mySide])
                    }
                }
                .padding(10)
            }
            .frame(height: 300)

            BattleLog(lines: battle.lines)

            Group {
                if let error = battle.error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                } else if battle.isOver {
                    VStack(spacing: 8) {
                        Text(resultText).font(.title2.bold())
                        Button("Done", action: onLeave).buttonStyle(.borderedProminent)
                    }
                } else if battle.waitingForOpponent {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Waiting for \(theirName)…")
                    }
                } else {
                    ChoiceGrid(options: battle.myOptions) { battle.choose($0) }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 130)
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .background(Color(.systemGroupedBackground))
        .overlay(alignment: .topTrailing) {
            if !battle.isOver {
                Button("Forfeit", role: .destructive) {
                    battle.forfeit()
                }
                .buttonStyle(.bordered)
                .padding(10)
            }
        }
    }

    private var resultText: String {
        switch battle.didIWin {
        case true?: "You win! 🎉"
        case false?: "\(theirName) wins"
        case nil: "It's a draw"
        }
    }
}

private struct HPCard: View {
    let title: String
    let combatant: BattleController.Combatant?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            HStack {
                Text(combatant?.name ?? "—").font(.subheadline.bold())
                if let status = combatant?.status {
                    Text(status.uppercased())
                        .font(.caption2.bold())
                        .padding(.horizontal, 4)
                        .background(.orange.opacity(0.8), in: .rect(cornerRadius: 3))
                }
            }
            ProgressView(value: combatant?.hpFraction ?? 0)
                .tint(barColor)
                .frame(width: 140)
                .animation(.easeOut(duration: 0.5), value: combatant?.hp)
            if let c = combatant, c.maxHP > 0 {
                Text("\(c.hp)/\(c.maxHP)").font(.caption2.monospacedDigit())
            }
        }
        .padding(8)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 10))
    }

    private var barColor: Color {
        let f = combatant?.hpFraction ?? 0
        return f > 0.5 ? .green : f > 0.2 ? .yellow : .red
    }
}

private struct BattleLog: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { item in
                        Text(item.element)
                            .font(item.element.hasPrefix("—") ? .caption.bold() : .callout)
                            .foregroundStyle(item.element.hasPrefix("—") ? .secondary : .primary)
                            .id(item.offset)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: lines.count) { _, count in
                withAnimation { proxy.scrollTo(count - 1, anchor: .bottom) }
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
    }
}

private struct ChoiceGrid: View {
    let options: [BattleController.Option]
    let onPick: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(options) { option in
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onPick(option.choice)
                } label: {
                    VStack(spacing: 2) {
                        Text(option.label).font(.subheadline.bold()).lineLimit(1).minimumScaleFactor(0.7)
                        if let detail = option.detail {
                            Text(detail).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.top, 8)
    }
}

/// A CPU battle launched from the home screen.
struct CPUBattleScreen: View {
    let team: [BattleMon]
    let pack: CreaturePack
    let onClose: () -> Void
    @State private var battle = BattleController(mySide: "p1", opponent: .cpu)

    var body: some View {
        BattleView(battle: battle, myName: "You", theirName: "CPU") {
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
            battle.start(seed: seed, p1: ("You", team), p2: ("CPU", cpuTeam))
        }
    }
}
