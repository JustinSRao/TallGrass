import SwiftUI
import TallGrassKit
import UniformTypeIdentifiers

struct HomeView: View {
    @Environment(PackStore.self) private var packs
    @AppStorage("lastTeam") private var savedTeam = Data()
    @AppStorage("playerName") private var playerName = ""
    @State private var hunt: HuntModel?
    @State private var match: MatchCoordinator?
    @State private var battling = false
    @State private var pickingPack = false

    private var team: [BattleMon] {
        (try? JSONDecoder().decode([BattleMon].self, from: savedTeam)) ?? []
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        match = MatchCoordinator(pack: packs.pack, myName: playerName.isEmpty ? "Player" : playerName)
                    } label: {
                        Label("Play with a Friend", systemImage: "person.2.fill").font(.headline)
                    }
                    Button {
                        hunt = HuntModel(pack: packs.pack, seed: UInt64.random(in: .min ... .max), player: 0)
                    } label: {
                        Label("Solo Hunt", systemImage: "camera.viewfinder")
                    }
                    Button {
                        battling = true
                    } label: {
                        Label("Battle the CPU", systemImage: "bolt.fill")
                    }
                    .disabled(team.isEmpty)
                } footer: {
                    Text("Find up to 6 creatures before time runs out. Rarer ones spawn further away, wander, leave sooner and are harder to catch. Then battle with real moves at level 50.")
                }

                if !team.isEmpty {
                    Section("Your Last Team") {
                        ForEach(Array(team.enumerated()), id: \.offset) { _, mon in
                            TeamRow(mon: mon)
                        }
                    }
                }

                Section {
                    LabeledContent("Pack", value: packs.isDemo ? "Built-in demo" : packs.pack.name)
                    LabeledContent("Species", value: "\(packs.pack.species.count)")
                    LabeledContent("3D models", value: "\(packs.modelCount)")
                    if let error = packs.loadError {
                        Text(error).foregroundStyle(.red).font(.footnote)
                    }
                    if packs.importing {
                        HStack { ProgressView(); Text("Importing… this can take a minute") }
                    } else {
                        Button("Import Pack…") { pickingPack = true }
                        Button("Reload Pack") { packs.reload() }
                    }
                } header: {
                    Text("Creature Pack")
                } footer: {
                    Text("Pick the TallGrass.creaturepack folder (for example from iCloud Drive or OneDrive). Or copy it into On My iPhone › TallGrass and tap Reload.")
                }
            }
            .navigationTitle("TallGrass")
            .fileImporter(isPresented: $pickingPack, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result {
                    Task { await packs.importPack(from: url) }
                }
            }
            .fullScreenCover(item: $hunt) { model in
                HuntView(model: model) { caught in
                    if !caught.isEmpty, let data = try? JSONEncoder().encode(caught) { savedTeam = data }
                    hunt = nil
                }
                .environment(packs)
            }
            .fullScreenCover(item: $match) { coordinator in
                MatchView(match: coordinator) { match = nil }
                    .environment(packs)
            }
            .fullScreenCover(isPresented: $battling) {
                CPUBattleScreen(team: team, pack: packs.pack) { battling = false }
                    .environment(packs)
            }
        }
    }
}

extension MatchCoordinator: Identifiable {
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
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
