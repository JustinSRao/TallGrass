import Foundation
import Testing
@testable import TallGrassKit

@Suite struct SeededRandomTests {
    @Test func sameSeedSameSequence() {
        var a = SeededRandom(seed: 42), b = SeededRandom(seed: 42)
        #expect((0..<100).map { _ in a.next() } == (0..<100).map { _ in b.next() })
    }

    @Test func labelsGiveIndependentStreams() {
        var a = SeededRandom(seed: 42, label: "spawns:0")
        var b = SeededRandom(seed: 42, label: "spawns:1")
        #expect(a.next() != b.next())
    }

    /// Pins the algorithm: if this changes, old match seeds replay differently.
    @Test func knownValue() {
        var rng = SeededRandom(seed: 0)
        #expect(rng.next() == 0xE220_A839_7B1D_CDAF)
    }

    @Test func boundsRespected() {
        var rng = SeededRandom(seed: 7)
        for _ in 0..<10_000 {
            #expect((0..<6).contains(rng.int(below: 6)))
            #expect((0...31).contains(rng.int(in: 0...31)))
            let u = rng.unit()
            #expect(u >= 0 && u < 1)
        }
    }

    @Test func weightedIndexSkipsZeroWeights() {
        var rng = SeededRandom(seed: 1)
        for _ in 0..<1_000 { #expect(rng.weightedIndex([0, 5, 0]) == 1) }
        #expect(rng.weightedIndex([0, 0]) == nil)
    }
}

@Suite struct RarityTests {
    @Test func classification() {
        #expect(Fixtures.pikachu.rarity == .common)
        #expect(Fixtures.pawmot.rarity == .rare)
        #expect(Fixtures.mewtwo.rarity == .legendary)
        #expect(Rarity.classify(catchRate: 45, baseStatTotal: 600, isLegendary: false) == .epic)
        #expect(Rarity.classify(catchRate: 3, baseStatTotal: 570, isLegendary: false) == .legendary)
    }

    @Test func rarerIsHarder() {
        for (a, b) in zip(Rarity.allCases, Rarity.allCases.dropFirst()) {
            #expect(a.spawnWeight > b.spawnWeight)
            #expect(a.baseCatchChance > b.baseCatchChance)
            #expect(a.fleeChancePerMiss < b.fleeChancePerMiss)
            #expect(a.lifetime.upperBound > b.lifetime.upperBound)
        }
        #expect(Rarity.allCases.map(\.spawnWeight).reduce(0, +) == 100)
    }
}

@Suite struct SpawnTests {
    let config = HuntConfig()

    @Test func deterministicPerSeedAndPlayer() {
        let planner = SpawnPlanner(species: Fixtures.all, config: config)
        #expect(planner.plan(seed: 99, player: 0) == planner.plan(seed: 99, player: 0))
        #expect(planner.plan(seed: 99, player: 0) != planner.plan(seed: 99, player: 1))
    }

    @Test func spawnsStayInsideTheRound() {
        let spawns = SpawnPlanner(species: Fixtures.all, config: config).plan(seed: 5, player: 0)
        #expect(!spawns.isEmpty)
        #expect(spawns.prefix(config.initialSpawns).allSatisfy { $0.appearsAt == 0 })
        for s in spawns {
            #expect(s.appearsAt < config.duration)
            #expect(s.rarity.spawnDistance.contains(s.distance))
            let species = Fixtures.all.first { $0.id == s.speciesID }!
            #expect(species.rarity == s.rarity)
            #expect((species.habitat == .air) == (s.height > 0))
        }
    }

    @Test func emptyPackGivesNoSpawns() {
        #expect(SpawnPlanner(species: [], config: config).plan(seed: 1, player: 0).isEmpty)
    }
}

@Suite struct HuntTests {
    @Test func catchingFillsTeamAndEndsHunt() {
        var config = HuntConfig()
        config.teamSize = 2
        var hunt = HuntSession(config: config, seed: 3, player: 0, species: [Fixtures.pikachu])
        var t = 0.0
        while !hunt.isOver(at: t), t < config.duration {
            for s in hunt.visible(at: t) { hunt.attemptCatch(spawnID: s.id, quality: 1, at: t) }
            t += 1
        }
        #expect(hunt.caught.count == 2)
        #expect(hunt.isTeamFull)
        #expect(hunt.visible(at: t).isEmpty)
    }

    @Test func cannotThrowAtSomethingNotThere() {
        var hunt = HuntSession(config: HuntConfig(), seed: 3, player: 0, species: Fixtures.all)
        #expect(hunt.attemptCatch(spawnID: 9_999, quality: 1, at: 0) == nil)
        #expect(hunt.attemptCatch(spawnID: 0, quality: 1, at: 10_000) == nil)
    }

    @Test func sameThrowsSameResults() {
        func run() -> [ThrowOutcome?] {
            var hunt = HuntSession(config: HuntConfig(), seed: 11, player: 1, species: Fixtures.all)
            return hunt.visible(at: 0).map { hunt.attemptCatch(spawnID: $0.id, quality: 0.5, at: 0) }
        }
        #expect(run() == run())
    }

    @Test func catchChanceShape() {
        let bad = CatchModel.chance(rarity: .rare, quality: 0, previousMisses: 0)
        let good = CatchModel.chance(rarity: .rare, quality: 1, previousMisses: 0)
        let persistent = CatchModel.chance(rarity: .rare, quality: 1, previousMisses: 3)
        #expect(bad < good && good < persistent)
        #expect(CatchModel.chance(rarity: .common, quality: 1, previousMisses: 99) <= 0.98)
    }
}

@Suite struct LoadoutTests {
    @Test func fourUniqueMovesWithStab() {
        for seed in UInt64(0)..<200 {
            var rng = SeededRandom(seed: seed)
            let mon = Loadout.roll(for: Fixtures.pawmot, shiny: false, rng: &rng)
            #expect(mon.moves.count == 4)
            #expect(Set(mon.moves).count == 4)
            let chosen = Fixtures.pawmot.movePool.filter { mon.moves.contains($0.name) }
            #expect(chosen.filter(\.isDamaging).count >= 2)
            #expect(chosen.contains { $0.isDamaging && Fixtures.pawmot.types.contains($0.type) })
            #expect(mon.level == 50)
            #expect([mon.ivs.hp, mon.ivs.atk, mon.ivs.def, mon.ivs.spa, mon.ivs.spd, mon.ivs.spe]
                .allSatisfy { (0...31).contains($0) })
        }
    }

    @Test func tinyMovePool() {
        var rng = SeededRandom(seed: 1)
        #expect(Loadout.roll(for: Fixtures.magikarp, shiny: true, rng: &rng).moves == ["Splash"])
    }

    @Test func hiddenAbilityIsRareButHappens() {
        var hidden = 0
        for seed in UInt64(0)..<2_000 {
            var rng = SeededRandom(seed: seed)
            if Loadout.roll(for: Fixtures.pikachu, shiny: false, rng: &rng).ability == "Lightning Rod" { hidden += 1 }
        }
        #expect(hidden > 150 && hidden < 350) // ~1/8 of 2000
    }
}

@Suite struct PackTests {
    @Test func roundTrip() throws {
        let pack = CreaturePack(name: "Test", species: Fixtures.all)
        let data = try JSONEncoder().encode(pack)
        #expect(try CreaturePack.decode(data).species == Fixtures.all)
    }

    @Test func rejectsOtherVersions() throws {
        let pack = CreaturePack(formatVersion: 99, name: "Future", species: Fixtures.all)
        let data = try JSONEncoder().encode(pack)
        #expect(throws: CreaturePack.PackError.unsupportedVersion(99)) { try CreaturePack.decode(data) }
    }
}
