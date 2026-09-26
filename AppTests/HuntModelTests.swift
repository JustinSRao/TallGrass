import XCTest
import TallGrassKit
@testable import TallGrass

@MainActor
final class HuntModelTests: XCTestCase {
    func testNothingSpawnsUntilStartedThenCreaturesAppear() {
        let model = HuntModel(pack: DemoPack.pack, seed: 42, player: 0)
        model.tick()
        XCTAssertTrue(model.visible.isEmpty, "a hunt that hasn't started shows nothing")
        XCTAssertEqual(model.timeRemaining, model.session.config.duration)

        model.start()
        model.tick()
        XCTAssertTrue(model.hasStarted)
        XCTAssertFalse(model.visible.isEmpty, "creatures must be there the moment a hunt starts")
    }

    func testScheduledStartCountsDown() {
        let model = HuntModel(pack: DemoPack.pack, seed: 42, player: 0)
        model.start(at: Date().addingTimeInterval(3))
        model.start()   // must not override a shared match start time
        model.tick()
        XCTAssertGreaterThan(model.countdown, 2)
        XCTAssertTrue(model.visible.isEmpty)
    }
}
