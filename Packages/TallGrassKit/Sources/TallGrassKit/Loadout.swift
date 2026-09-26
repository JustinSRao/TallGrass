import Foundation

/// A caught creature ready for battle, in the shape the battle engine takes
/// (BattleEngine/src/engine.js `toSet`). Everyone battles at level 50 with
/// no EVs: there is no levelling, so the "gacha" is in these rolls.
public struct BattleMon: Codable, Hashable, Sendable {
    public var species: String
    public var nickname: String?
    public var ability: String
    public var moves: [String]
    public var nature: String
    public var ivs: Stats
    public var level: Int
    public var shiny: Bool

    public struct Stats: Codable, Hashable, Sendable {
        public var hp, atk, def, spa, spd, spe: Int
    }
}

public enum Loadout {
    public static let natures = [
        "Hardy", "Lonely", "Brave", "Adamant", "Naughty", "Bold", "Docile", "Relaxed",
        "Impish", "Lax", "Timid", "Hasty", "Serious", "Jolly", "Naive", "Modest",
        "Mild", "Quiet", "Bashful", "Rash", "Calm", "Gentle", "Sassy", "Careful", "Quirky",
    ]

    /// Chance of rolling the hidden ability instead of a regular one.
    public static let hiddenAbilityChance = 1.0 / 8

    /// Rolls a battle-ready loadout for a caught creature.
    ///
    /// Moves are random but never useless: at least one same-type damaging
    /// move when the species has one, at least two damaging moves in total,
    /// and no duplicates. Species with fewer than four legal moves (Magikarp,
    /// Ditto) just get what they have.
    public static func roll(for species: CreatureSpecies, shiny: Bool, rng: inout SeededRandom) -> BattleMon {
        var moves: [MoveOption] = []
        let pool = species.movePool
        let damaging = pool.filter(\.isDamaging)
        let stab = damaging.filter { species.types.contains($0.type) }

        func take(_ candidates: [MoveOption]) {
            let fresh = candidates.filter { !moves.contains($0) }
            if let m = rng.pick(fresh) { moves.append(m) }
        }

        if !stab.isEmpty { take(stab) }
        while moves.filter(\.isDamaging).count < 2,
              damaging.contains(where: { !moves.contains($0) }) {
            take(damaging)
        }
        while moves.count < 4, pool.contains(where: { !moves.contains($0) }) {
            take(pool)
        }

        let useHidden = species.hiddenAbility != nil && rng.chance(hiddenAbilityChance)
        let ability = useHidden ? species.hiddenAbility! : (rng.pick(species.abilities) ?? "No Ability")

        func iv() -> Int { rng.int(in: 0...31) }
        return BattleMon(
            species: species.name, nickname: nil, ability: ability,
            moves: moves.map(\.name), nature: rng.pick(natures) ?? "Hardy",
            ivs: .init(hp: iv(), atk: iv(), def: iv(), spa: iv(), spd: iv(), spe: iv()),
            level: 50, shiny: shiny)
    }
}
