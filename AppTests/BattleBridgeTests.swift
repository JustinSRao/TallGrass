import XCTest
import TallGrassKit
@testable import TallGrass

/// Runs the real bundled Showdown engine in JavaScriptCore, the same way the
/// app does, so a bad bundle or a bridge mismatch fails CI instead of a phone.
@MainActor
final class BattleBridgeTests: XCTestCase {
    private func team(seed: UInt64) -> [BattleMon] {
        var rng = SeededRandom(seed: seed)
        return DemoPack.pack.species.map { Loadout.roll(for: $0, shiny: false, rng: &rng) }
    }

    private func play(seed: [UInt16]) throws -> (winner: String?, events: [String]) {
        let bridge = try BattleBridge()
        var update = try bridge.start(seed: seed, p1: ("You", team(seed: 1)), p2: ("CPU", team(seed: 2)))
        let id = try XCTUnwrap(update.id)
        var events = update.events
        var turns = 0
        while update.winner == nil, turns < 400 {
            turns += 1
            for side in ["p1", "p2"] {
                guard let request = update.requests[side] ?? nil, request.isActionable else { continue }
                update = try bridge.choose(battle: id, side: side, choice: request.legalChoices[0])
                XCTAssertNil(update.error)
                events += update.events
                if update.winner != nil { break }
            }
        }
        bridge.end(battle: id)
        return (update.winner, events)
    }

    func testFullBattleFinishes() throws {
        let result = try play(seed: [1, 2, 3, 4])
        XCTAssertNotNil(result.winner)
        XCTAssertTrue(result.events.contains { $0.hasPrefix("|turn|") })
    }

    func testSameSeedSameBattle() throws {
        XCTAssertEqual(try play(seed: [7, 7, 7, 7]).events, try play(seed: [7, 7, 7, 7]).events)
    }

    func testRejectsIllegalChoice() throws {
        let bridge = try BattleBridge()
        let update = try bridge.start(seed: [1, 1, 1, 1], p1: ("You", team(seed: 3)), p2: ("CPU", team(seed: 4)))
        let rejected = try bridge.choose(battle: try XCTUnwrap(update.id), side: "p1", choice: "move 9")
        XCTAssertNotNil(rejected.error)
    }
}
