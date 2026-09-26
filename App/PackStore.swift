import Foundation
import Observation
import TallGrassKit

/// Finds the creature pack the user copied into the app's Documents folder
/// (Files app › On My iPhone › TallGrass, or Finder / Apple Devices on a
/// computer). Falls back to the small built-in demo pack, which has no 3D
/// models, so the app always works.
@MainActor @Observable
final class PackStore {
    private(set) var pack: CreaturePack = DemoPack.pack
    private(set) var packURL: URL?
    private(set) var loadError: String?

    init() {
        reload()
    }

    var isDemo: Bool { packURL == nil }

    static var documentsPackURL: URL {
        URL.documentsDirectory.appending(path: CreaturePack.folderName, directoryHint: .isDirectory)
    }

    func reload() {
        let folder = Self.documentsPackURL
        let manifest = folder.appending(path: "manifest.json")
        guard FileManager.default.fileExists(atPath: manifest.path(percentEncoded: false)) else {
            pack = DemoPack.pack
            packURL = nil
            loadError = nil
            return
        }
        do {
            pack = try CreaturePack.decode(Data(contentsOf: manifest))
            packURL = folder
            loadError = nil
        } catch {
            pack = DemoPack.pack
            packURL = nil
            loadError = "Couldn't read \(CreaturePack.folderName): \(error)"
        }
    }

    var modelCount: Int {
        pack.species.filter { modelURL(for: $0) != nil }.count
    }

    func modelURL(for species: CreatureSpecies) -> URL? {
        guard let key = species.modelKey, let packURL else { return nil }
        let url = packURL.appending(path: "models/\(key).usdz")
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    func species(id: String) -> CreatureSpecies? {
        pack.species.first { $0.id == id }
    }
}

/// A few species so the app is playable with no pack installed. Names and
/// moves only; no game art.
enum DemoPack {
    private static func move(_ name: String, _ type: String, _ category: String, _ power: Int) -> MoveOption {
        MoveOption(name: name, type: type, category: category, power: power)
    }

    static let pack = CreaturePack(name: "Demo", species: [
        CreatureSpecies(id: "pikachu", name: "Pikachu", national: 25, types: ["Electric"],
                        abilities: ["Static"], hiddenAbility: "Lightning Rod",
                        catchRate: 190, baseStatTotal: 320, movePool: [
                            move("Thunderbolt", "Electric", "Special", 90),
                            move("Quick Attack", "Normal", "Physical", 40),
                            move("Iron Tail", "Steel", "Physical", 100),
                            move("Thunder Wave", "Electric", "Status", 0),
                            move("Nuzzle", "Electric", "Physical", 20),
                        ]),
        CreatureSpecies(id: "psyduck", name: "Psyduck", national: 54, types: ["Water"],
                        abilities: ["Damp", "Cloud Nine"], hiddenAbility: "Swift Swim",
                        catchRate: 190, baseStatTotal: 320, habitat: .water, movePool: [
                            move("Water Pulse", "Water", "Special", 60),
                            move("Confusion", "Psychic", "Special", 50),
                            move("Zen Headbutt", "Psychic", "Physical", 80),
                            move("Scratch", "Normal", "Physical", 40),
                        ]),
        CreatureSpecies(id: "fletchling", name: "Fletchling", national: 661, types: ["Normal", "Flying"],
                        abilities: ["Big Pecks"], hiddenAbility: "Gale Wings",
                        catchRate: 255, baseStatTotal: 278, habitat: .air, movePool: [
                            move("Peck", "Flying", "Physical", 35),
                            move("Quick Attack", "Normal", "Physical", 40),
                            move("Flame Charge", "Fire", "Physical", 50),
                            move("Agility", "Psychic", "Status", 0),
                        ]),
        CreatureSpecies(id: "pawmot", name: "Pawmot", national: 923, types: ["Electric", "Fighting"],
                        abilities: ["Volt Absorb", "Natural Cure"], hiddenAbility: "Iron Fist",
                        catchRate: 45, baseStatTotal: 490, movePool: [
                            move("Double Shock", "Electric", "Physical", 120),
                            move("Close Combat", "Fighting", "Physical", 120),
                            move("Wild Charge", "Electric", "Physical", 90),
                            move("Bite", "Dark", "Physical", 60),
                            move("Nuzzle", "Electric", "Physical", 20),
                        ]),
        CreatureSpecies(id: "dragonite", name: "Dragonite", national: 149, types: ["Dragon", "Flying"],
                        abilities: ["Inner Focus"], hiddenAbility: "Multiscale",
                        catchRate: 45, baseStatTotal: 600, habitat: .air, movePool: [
                            move("Extreme Speed", "Normal", "Physical", 80),
                            move("Dragon Claw", "Dragon", "Physical", 80),
                            move("Earthquake", "Ground", "Physical", 100),
                            move("Fire Punch", "Fire", "Physical", 75),
                            move("Dragon Dance", "Dragon", "Status", 0),
                        ]),
        CreatureSpecies(id: "mewtwo", name: "Mewtwo", national: 150, types: ["Psychic"],
                        abilities: ["Pressure"], hiddenAbility: "Unnerve",
                        catchRate: 3, baseStatTotal: 680, isLegendary: true, habitat: .air, movePool: [
                            move("Psystrike", "Psychic", "Special", 100),
                            move("Aura Sphere", "Fighting", "Special", 80),
                            move("Ice Beam", "Ice", "Special", 90),
                            move("Recover", "Normal", "Status", 0),
                        ]),
    ])
}
