import XCTest
import TallGrassKit
@testable import TallGrass

/// Two BattleControllers wired together like two phones: each only learns
/// the other's choices through `send`/`receive`. They must finish the whole
/// battle with identical logs and agree on the winner.
@MainActor
final class LockstepTests: XCTestCase {
    private func team(seed: UInt64) -> [BattleMon] {
        var rng = SeededRandom(seed: seed)
        return DemoPack.pack.species.map { Loadout.roll(for: $0, shiny: false, rng: &rng) }
    }

    func testTwoPhonesStayInSync() throws {
        var host: BattleController!
        var guest: BattleController!
        // Messages are delivered after the sender finishes, like a real network.
        var inbox: [(to: String, round: Int, side: String, choice: String)] = []
        host = BattleController(mySide: "p1", opponent: .remote(send: { inbox.append(("guest", $0, $1, $2)) }))
        guest = BattleController(mySide: "p2", opponent: .remote(send: { inbox.append(("host", $0, $1, $2)) }))

        let seed: [UInt16] = [11, 22, 33, 44]
        let a = team(seed: 1), b = team(seed: 2)
        host.start(seed: seed, p1: ("Host", a), p2: ("Guest", b))
        guest.start(seed: seed, p1: ("Host", a), p2: ("Guest", b))
        XCTAssertNil(host.error)
        XCTAssertNil(guest.error)

        var rng = SeededRandom(seed: 99)
        var steps = 0
        while !(host.isOver && guest.isOver), steps < 2_000 {
            steps += 1
            // Each side picks randomly among its legal options, in varying order.
            let order = rng.chance(0.5) ? [host!, guest!] : [guest!, host!]
            for player in order where !player.myOptions.isEmpty {
                player.choose(rng.pick(player.myOptions)!.choice)
            }
            while !inbox.isEmpty {
                let m = inbox.removeFirst()
                (m.to == "host" ? host : guest)!.receive(round: m.round, side: m.side, choice: m.choice)
            }
            XCTAssertNil(host.error, "host: \(host.error ?? "")")
            XCTAssertNil(guest.error, "guest: \(guest.error ?? "")")
            if host.error != nil || guest.error != nil { break }
        }

        XCTAssertTrue(host.isOver && guest.isOver, "battle did not finish in \(steps) steps")
        XCTAssertEqual(host.stageEvents, guest.stageEvents)
        XCTAssertEqual(host.round, guest.round)
        XCTAssertEqual(host.winnerName, guest.winnerName)
        if let hostWon = host.didIWin, let guestWon = guest.didIWin {
            XCTAssertNotEqual(hostWon, guestWon, "exactly one side should win")
        }
    }

    func testCPUBattleFinishes() throws {
        let battle = BattleController(mySide: "p1", opponent: .cpu)
        battle.start(seed: [1, 2, 3, 4], p1: ("You", team(seed: 5)), p2: ("CPU", team(seed: 6)))
        var steps = 0
        while !battle.isOver, steps < 1_000, let option = battle.myOptions.first {
            battle.choose(option.choice)
            steps += 1
        }
        XCTAssertNil(battle.error)
        XCTAssertTrue(battle.isOver)
        XCTAssertFalse(battle.lines.isEmpty)
    }
}
