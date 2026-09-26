import MultipeerConnectivity
import SwiftUI
import TallGrassKit

/// Full-screen two-player flow.
struct MatchView: View {
    @State var match: MatchCoordinator
    let onClose: () -> Void
    @Environment(PackStore.self) private var packs
    @AppStorage("playerName") private var playerName = ""

    var body: some View {
        Group {
            switch match.phase {
            case .lobby:
                LobbyView(match: match, onClose: close)
            case .hunting:
                if let hunt = match.hunt {
                    HuntView(model: hunt, showsResults: false,
                             opponentStatus: "\(match.friendName): \(match.friendCaught)/\(match.config.teamSize) caught") { team in
                        match.huntFinished(team: team)
                    }
                    .onChange(of: hunt.team.count) { _, _ in match.reportProgress() }
                }
            case .waitingForFriend:
                WaitingView(match: match)
            case .reveal:
                RevealView(match: match, onClose: close)
            case .battle:
                if let battle = match.battle {
                    BattleView(battle: battle, myName: match.battleNames.0, theirName: match.battleNames.1) {
                        match.leaveBattle()
                    }
                }
            }
        }
        .onChange(of: match.connection.state) { _, _ in match.connectionChanged() }
        .alert("Heads up", isPresented: Binding(get: { match.notice != nil && match.phase != .battle },
                                                set: { _ in })) {
            Button("OK") {}
        } message: {
            Text(match.notice ?? "")
        }
    }

    private func close() {
        match.leave()
        onClose()
    }
}

private struct LobbyView: View {
    @Bindable var match: MatchCoordinator
    let onClose: () -> Void
    @AppStorage("playerName") private var playerName = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("You") {
                    TextField("Your name", text: $playerName)
                        .onChange(of: playerName) { _, name in match.myName = name.isEmpty ? "Player" : name }
                }

                Section {
                    switch match.connection.state {
                    case .idle:
                        Button("Host a Match") { match.connection.host() }
                        Button("Join a Friend") { match.connection.join() }
                    case .searching:
                        if match.isHost {
                            Label("Waiting for your friend to join…", systemImage: "antenna.radiowaves.left.and.right")
                        } else if match.connection.nearbyHosts.isEmpty {
                            Label("Looking for a nearby host…", systemImage: "magnifyingglass")
                        } else {
                            ForEach(match.connection.nearbyHosts, id: \.self) { peer in
                                Button("Join \(peer.displayName)") { match.connection.invite(peer) }
                            }
                        }
                        Button("Cancel", role: .cancel) { match.connection.stop() }
                    case .connecting(let name):
                        Label("Connecting to \(name)…", systemImage: "link")
                    case .connected:
                        Label("Connected to \(match.friendName)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .failed(let reason):
                        Text(reason).foregroundStyle(.red)
                        Button("Try Again") { match.connection.stop() }
                    }
                } header: {
                    Text("Friend")
                } footer: {
                    Text("Both phones need Wi-Fi or Bluetooth on and should be near each other. No internet needed.")
                }

                if match.isHost && match.connection.isConnected {
                    Section("Rules") {
                        Picker("Hunt length", selection: $match.config.duration) {
                            Text("1 min").tag(60.0)
                            Text("2 min").tag(120.0)
                            Text("3 min").tag(180.0)
                            Text("5 min").tag(300.0)
                        }
                        Picker("Team size", selection: $match.config.teamSize) {
                            Text("3").tag(3)
                            Text("6").tag(6)
                        }
                        Picker("Luck", selection: $match.config.luck) {
                            Text("Normal").tag(1.0)
                            Text("Lucky (more rares)").tag(2.5)
                        }
                    }
                    Section {
                        Button("Start the Hunt!") { match.startHunt() }
                            .font(.headline)
                    }
                } else if match.connection.isConnected {
                    Section {
                        Label("\(match.friendName) is choosing the rules…", systemImage: "hourglass")
                    }
                }
            }
            .navigationTitle("Play with a Friend")
            .toolbar {
                Button("Close", action: onClose)
            }
            .onAppear { match.myName = playerName.isEmpty ? "Player" : playerName }
        }
    }
}

private struct WaitingView: View {
    let match: MatchCoordinator

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Waiting for \(match.friendName) to finish hunting…")
                .font(.headline)
            Text("\(match.friendName) has caught \(match.friendCaught) so far.")
                .foregroundStyle(.secondary)
            TeamList(title: "Your team", team: match.myTeam)
        }
        .padding()
    }
}

private struct RevealView: View {
    let match: MatchCoordinator
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    TeamList(title: "Your team", team: match.myTeam)
                    Text("VS").font(.largeTitle.weight(.black))
                    TeamList(title: "\(match.friendName)'s team", team: match.theirTeam ?? [])
                }
                .padding()
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if match.myTeam.isEmpty || (match.theirTeam ?? []).isEmpty {
                        Text("Someone caught nothing, so there's no battle. Hunt again!")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else if match.isHost {
                        Button("Battle!") { match.startBattle() }
                            .buttonStyle(.borderedProminent)
                            .font(.headline)
                    } else {
                        Text("Waiting for \(match.friendName) to start the battle…")
                            .foregroundStyle(.secondary)
                    }
                    if match.isHost {
                        Button("Hunt Again") { match.startHunt() }
                            .buttonStyle(.bordered)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
            .navigationTitle("Teams")
            .toolbar { Button("Leave", action: onClose) }
        }
    }
}

struct TeamList: View {
    let title: String
    let team: [BattleMon]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if team.isEmpty {
                Text("No creatures").foregroundStyle(.secondary)
            }
            ForEach(Array(team.enumerated()), id: \.offset) { _, mon in
                TeamRow(mon: mon)
                    .padding(10)
                    .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
