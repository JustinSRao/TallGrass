import Foundation
import Observation
import TallGrassKit

/// Finds the creature pack in the app's Documents folder. It gets there by
/// "Import Pack…" (a folder picked in the Files app, e.g. from iCloud Drive or
/// OneDrive), or by copying it in with Finder / Apple Devices. Falls back to
/// the small built-in demo pack, which has no 3D models, so the app always works.
@MainActor @Observable
final class PackStore {
    private(set) var pack: CreaturePack = DemoPack.pack
    private(set) var packURL: URL?
    private(set) var loadError: String?
    private(set) var modelCount = 0
    private(set) var importing = false
    private var byName: [String: CreatureSpecies] = [:]
    private var modelFiles: Set<String> = []

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
        defer { index() }
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

    private func index() {
        byName = Dictionary(pack.species.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        metaCache = [:]
        modelFiles = []
        if let packURL,
           let names = try? FileManager.default.contentsOfDirectory(atPath: packURL.appending(path: "models").path(percentEncoded: false)) {
            modelFiles = Set(names)
        }
        modelCount = pack.species.filter { $0.modelKey.map { modelFiles.contains("\($0).usdz") } ?? false }.count
    }

    /// The species' model, or its shiny variant when asked and available.
    func modelURL(for species: CreatureSpecies, shiny: Bool = false) -> URL? {
        guard let key = species.modelKey, let packURL else { return nil }
        if shiny, modelFiles.contains("\(key)_rare.usdz") {
            return packURL.appending(path: "models/\(key)_rare.usdz")
        }
        return modelFiles.contains("\(key).usdz") ? packURL.appending(path: "models/\(key).usdz") : nil
    }

    @ObservationIgnored private var metaCache: [String: ModelMeta] = [:]

    /// Clip ranges and material layout for a species' model, if the pack has them.
    func modelMeta(for species: CreatureSpecies) -> ModelMeta? {
        guard let key = species.modelKey, let packURL, modelFiles.contains("\(key).json") else { return nil }
        if let cached = metaCache[key] { return cached }
        let meta = try? JSONDecoder().decode(ModelMeta.self,
                                             from: Data(contentsOf: packURL.appending(path: "models/\(key).json")))
        metaCache[key] = meta
        return meta
    }

    /// A shiny texture (`models/<key>_rare/<stem>.png`), if the pack has one.
    func shinyTextureURL(for species: CreatureSpecies, stem: String) -> URL? {
        guard let key = species.modelKey, let packURL, modelFiles.contains("\(key)_rare") else { return nil }
        let url = packURL.appending(path: "models/\(key)_rare/\(stem).png")
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    func species(id: String) -> CreatureSpecies? {
        pack.species.first { $0.id == id }
    }

    /// Looks up by display name, as the battle engine reports it ("Pawmot").
    func species(named name: String) -> CreatureSpecies? {
        byName[name]
    }

    /// Copies a picked `TallGrass.creaturepack` folder into Documents, replacing
    /// any existing pack. The copy runs off the main thread (packs are large).
    func importPack(from picked: URL) async {
        importing = true
        defer { importing = false }
        let destination = Self.documentsPackURL
        let result: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
            let scoped = picked.startAccessingSecurityScopedResource()
            defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
            do {
                let fm = FileManager.default
                guard fm.fileExists(atPath: picked.appending(path: "manifest.json").path(percentEncoded: false)) else {
                    throw CocoaError(.fileReadNoSuchFile, userInfo: [NSLocalizedDescriptionKey:
                        "That folder has no manifest.json. Pick the TallGrass.creaturepack folder itself."])
                }
                let staging = destination.deletingLastPathComponent().appending(path: "incoming.creaturepack")
                try? fm.removeItem(at: staging)
                try fm.copyItem(at: picked, to: staging)
                try? fm.removeItem(at: destination)
                try fm.moveItem(at: staging, to: destination)
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value
        if case .failure(let error) = result {
            loadError = "Import failed: \(error.localizedDescription)"
            return
        }
        reload()
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
