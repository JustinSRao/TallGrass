@testable import TallGrassKit

enum Fixtures {
    static let thunderbolt = MoveOption(name: "Thunderbolt", type: "Electric", category: "Special", power: 90)
    static let closeCombat = MoveOption(name: "Close Combat", type: "Fighting", category: "Physical", power: 120)
    static let quickAttack = MoveOption(name: "Quick Attack", type: "Normal", category: "Physical", power: 40, priority: 1)
    static let bite = MoveOption(name: "Bite", type: "Dark", category: "Physical", power: 60)
    static let thunderWave = MoveOption(name: "Thunder Wave", type: "Electric", category: "Status", power: 0, accuracy: 90)
    static let agility = MoveOption(name: "Agility", type: "Psychic", category: "Status", power: 0, accuracy: 101)
    static let protect = MoveOption(name: "Protect", type: "Normal", category: "Status", power: 0, accuracy: 101, priority: 4)
    static let charge = MoveOption(name: "Charge", type: "Electric", category: "Status", power: 0, accuracy: 101)

    static let pawmot = CreatureSpecies(
        id: "pawmot", name: "Pawmot", national: 923, types: ["Electric", "Fighting"],
        abilities: ["Volt Absorb", "Natural Cure"], hiddenAbility: "Iron Fist",
        catchRate: 45, baseStatTotal: 490,
        movePool: [thunderbolt, closeCombat, quickAttack, bite, thunderWave, agility, protect, charge])

    static let pikachu = CreatureSpecies(
        id: "pikachu", name: "Pikachu", national: 25, types: ["Electric"],
        abilities: ["Static"], hiddenAbility: "Lightning Rod",
        catchRate: 190, baseStatTotal: 320,
        movePool: [thunderbolt, quickAttack, thunderWave, agility])

    static let magikarp = CreatureSpecies(
        id: "magikarp", name: "Magikarp", national: 129, types: ["Water"],
        abilities: ["Swift Swim"], hiddenAbility: "Rattled",
        catchRate: 255, baseStatTotal: 200,
        movePool: [MoveOption(name: "Splash", type: "Normal", category: "Status", power: 0, accuracy: 101)])

    static let mewtwo = CreatureSpecies(
        id: "mewtwo", name: "Mewtwo", national: 150, types: ["Psychic"],
        abilities: ["Pressure"], hiddenAbility: "Unnerve",
        catchRate: 3, baseStatTotal: 680, isLegendary: true, habitat: .air,
        movePool: [agility, protect])

    static let all = [pawmot, pikachu, magikarp, mewtwo]
}
