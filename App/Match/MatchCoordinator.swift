import Foundation
import Observation
import TallGrassKit

/// The two-player flow: lobby → synced hunt → team reveal → lockstep battle.
///
/// The host makes every "shared" decision (rules, seeds, when to start) and
/// sends it; both phones then do the same deterministic work. Host is p1 in
/// battle, guest is p2.
@MainActor @Observable
final class MatchCoordinator {
    enum Phase: Equatable {
        case lobby
        case hunting
        case waitingForFriend
        case reveal
        case battle
    }

    let connection = MatchConnection()
    private(set) var phase: Phase = .lobby
    private(set) var hunt: HuntModel?
    private(set) var battle: BattleController?
    private(set) var myTeam: [BattleMon] = []
    private(set) var theirTeam: [BattleMon]?
    private(set) var friendName = "Friend"
    private(set) var friendCaught = 0
    private(set) var notice: String?
    /// (me, friend) as shown in the current battle.
    private(set) var battleNames = ("You", "Friend")
    var config = HuntConfig()
    var myName: String

    private let pack: CreaturePack

    init(pack: CreaturePack, myName: String) {
        self.pack = pack
        self.myName = myName
        connection.onMessage = { [weak self] message in self?.handle(message) }
    }

    var isHost: Bool { connection.role == .host }
    var canStartHunt: Bool { isHost && connection.isConnected && phase != .hunting }

    // MARK: Actions (host decides, both run)

    func startHunt() {
        guard canStartHunt else { return }
        let seed = UInt64.random(in: .min ... .max)
        let startAt = Date().addingTimeInterval(4)
        connection.send(.startHunt(seed: seed, config: config, startAt: startAt))
        beginHunt(seed: seed, config: config, startAt: startAt)
    }

    func startBattle() {
        guard isHost, theirTeam != nil else { return }
        let seed = (0..<4).map { _ in UInt16.random(in: .min ... .max) }
        connection.send(.startBattle(seed: seed))
        beginBattle(seed: seed)
    }

    func huntFinished(team: [BattleMon]) {
        myTeam = team
        connection.send(.team(team))
        hunt = nil
        phase = theirTeam == nil ? .waitingForFriend : .reveal
    }

    func leaveBattle() {
        battle?.finish()
        battle = nil
        phase = .reveal
    }

    func leave() {
        connection.send(.leave)
        battle?.finish()
        connection.stop()
    }

    func reportProgress() {
        if let hunt { connection.send(.progress(caught: hunt.team.count)) }
    }

    // MARK: Messages

    private func handle(_ message: MatchMessage) {
        switch message {
        case .hello(let name, let version, let packName, let packSpecies):
            friendName = name
            if version != MatchConnection.protocolVersion {
                notice = "\(name) has a different app version. Update both phones to the same TestFlight build."
            } else if packSpecies != pack.species.count {
                notice = "\(name)'s creature pack (\(packName), \(packSpecies) species) differs from yours. You can still play; the hunts just won't have the same creatures."
            }
        case .startHunt(let seed, let config, let startAt):
            self.config = config
            beginHunt(seed: seed, config: config, startAt: startAt)
        case .progress(let caught):
            friendCaught = caught
        case .team(let team):
            theirTeam = team
            if phase == .waitingForFriend { phase = .reveal }
        case .startBattle(let seed):
            beginBattle(seed: seed)
        case .choice(let round, let side, let choice):
            battle?.receive(round: round, side: side, choice: choice)
        case .rematch:
            leaveBattle()
        case .leave:
            battle?.opponentLeft()
            notice = "\(friendName) left the match."
        }
    }

    func sayHello() {
        connection.send(.hello(name: myName, protocolVersion: MatchConnection.protocolVersion,
                               packName: pack.name, packSpecies: pack.species.count))
    }

    // MARK: Phases

    private func beginHunt(seed: UInt64, config: HuntConfig, startAt: Date) {
        myTeam = []
        theirTeam = nil
        friendCaught = 0
        battle?.finish()
        battle = nil
        let model = HuntModel(pack: pack, seed: seed, player: isHost ? 0 : 1, config: config)
        model.start(at: startAt)
        hunt = model
        phase = .hunting
    }

    private func beginBattle(seed: [UInt16]) {
        guard let theirTeam else { return }
        let connection = self.connection
        let controller = BattleController(mySide: isHost ? "p1" : "p2", opponent: .remote(send: { round, side, choice in
            connection.send(.choice(round: round, side: side, choice: choice))
        }))
        // Both phones must pass identical sides in identical order.
        let hostSide = isHost ? (myName, myTeam) : (friendName, theirTeam)
        var guestSide = isHost ? (friendName, theirTeam) : (myName, myTeam)
        // The winner is reported by name, so names must differ (same rule on both phones).
        if guestSide.0 == hostSide.0 { guestSide.0 += " 2" }
        controller.start(seed: seed, p1: (hostSide.0, hostSide.1), p2: (guestSide.0, guestSide.1))
        battleNames = isHost ? (hostSide.0, guestSide.0) : (guestSide.0, hostSide.0)
        battle = controller
        phase = .battle
    }

    func connectionChanged() {
        switch connection.state {
        case .connected:
            sayHello()
        case .failed(let reason):
            notice = reason
            battle?.opponentLeft()
        default:
            break
        }
    }
}
