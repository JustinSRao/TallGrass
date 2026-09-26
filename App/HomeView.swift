import SwiftUI
import TallGrassKit

struct HomeView: View {
    @Environment(PackStore.self) private var packs
    @State private var hunt: HuntModel?
    @State private var team: [BattleMon] = []
    @State private var battling = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        hunt = HuntModel(pack: packs.pack, seed: UInt64.random(in: .min ... .max), player: 0)
                    } label: {
                        Label("Start a Hunt", systemImage: "camera.viewfinder")
                            .font(.headline)
                    }
                    Button {
                        battling = true
                    } label: {
                        Label("Battle the CPU", systemImage: "bolt.fill")
                    }
                    .disabled(team.isEmpty)
                } footer: {
                    Text("Find up to 6 creatures in 3 minutes. Rarer ones spawn further away, leave sooner and are harder to catch.")
                }

                if !team.isEmpty {
                    Section("Your Team") {
                        ForEach(team, id: \.self) { mon in
                            TeamRow(mon: mon)
                        }
                    }
                }

                Section("Creature Pack") {
                    LabeledContent("Pack", value: packs.isDemo ? "Built-in demo" : packs.pack.name)
                    LabeledContent("Species", value: "\(packs.pack.species.count)")
                    LabeledContent("3D models", value: "\(packs.modelCount)")
                    if let error = packs.loadError {
                        Text(error).foregroundStyle(.red).font(.footnote)
                    }
                    Button("Reload Pack") { packs.reload() }
                }
            }
            .navigationTitle("TallGrass")
            .fullScreenCover(item: $hunt) { model in
                HuntView(model: model) { caught in
                    if !caught.isEmpty { team = caught }
                    hunt = nil
                }
                .environment(packs)
            }
            .fullScreenCover(isPresented: $battling) {
                BattleView(playerTeam: team, pack: packs.pack) { battling = false }
            }
        }
    }
}

struct TeamRow: View {
    let mon: BattleMon

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(mon.species).font(.headline)
                if mon.shiny { Image(systemName: "sparkles").foregroundStyle(.yellow) }
                Spacer()
                Text("\(mon.nature) · \(mon.ability)").font(.caption).foregroundStyle(.secondary)
            }
            Text(mon.moves.joined(separator: " · ")).font(.caption)
        }
    }
}
