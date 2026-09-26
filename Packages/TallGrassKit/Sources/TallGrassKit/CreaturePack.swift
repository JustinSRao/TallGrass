import Foundation

/// The on-device creature pack: `TallGrass.creaturepack/manifest.json` plus
/// one `models/<modelKey>.usdz` per species.
///
/// The pack is built on the PC by `pipeline/` from the user's own game dump
/// and copied onto the phone (Files / Finder / Apple Devices). It is never
/// compiled into the app, so TestFlight builds contain no game assets.
public struct CreaturePack: Codable, Sendable {
    public static let formatVersion = 1
    public static let folderName = "TallGrass.creaturepack"

    public var formatVersion: Int
    public var name: String
    public var builtAt: Date?
    public var species: [CreatureSpecies]

    public init(formatVersion: Int = CreaturePack.formatVersion, name: String,
                builtAt: Date? = nil, species: [CreatureSpecies]) {
        self.formatVersion = formatVersion
        self.name = name
        self.builtAt = builtAt
        self.species = species
    }

    public static func decode(_ data: Data) throws -> CreaturePack {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let pack = try decoder.decode(CreaturePack.self, from: data)
        guard pack.formatVersion == formatVersion else {
            throw PackError.unsupportedVersion(pack.formatVersion)
        }
        guard !pack.species.isEmpty else { throw PackError.empty }
        return pack
    }

    public enum PackError: Error, Equatable {
        case unsupportedVersion(Int)
        case empty
    }
}

public struct CreatureSpecies: Codable, Hashable, Sendable, Identifiable {
    /// Showdown ID, e.g. "pawmot". This is what the battle engine uses.
    public var id: String
    public var name: String
    public var national: Int
    public var types: [String]
    public var abilities: [String]
    public var hiddenAbility: String?
    public var catchRate: Int
    public var baseStatTotal: Int
    public var isLegendary: Bool
    public var isMythical: Bool
    public var isParadox: Bool
    /// File stem under `models/`, or nil when the pack has no model for it
    /// (the app then shows a placeholder).
    public var modelKey: String?
    public var habitat: Habitat
    public var movePool: [MoveOption]

    public init(id: String, name: String, national: Int, types: [String],
                abilities: [String], hiddenAbility: String? = nil, catchRate: Int,
                baseStatTotal: Int, isLegendary: Bool = false, isMythical: Bool = false,
                isParadox: Bool = false, modelKey: String? = nil,
                habitat: Habitat = .ground, movePool: [MoveOption]) {
        self.id = id
        self.name = name
        self.national = national
        self.types = types
        self.abilities = abilities
        self.hiddenAbility = hiddenAbility
        self.catchRate = catchRate
        self.baseStatTotal = baseStatTotal
        self.isLegendary = isLegendary
        self.isMythical = isMythical
        self.isParadox = isParadox
        self.modelKey = modelKey
        self.habitat = habitat
        self.movePool = movePool
    }

    public var rarity: Rarity {
        Rarity.classify(catchRate: catchRate, baseStatTotal: baseStatTotal,
                        isLegendary: isLegendary || isMythical)
    }
}

/// Where a species appears in the camera view.
public enum Habitat: String, Codable, Sendable {
    case ground   // standing on a detected floor/table
    case air      // hovering 1–2.5 m up
    case water    // floor too, for now; could prefer low/blue surfaces later
}

public struct MoveOption: Codable, Hashable, Sendable {
    public var name: String
    public var type: String
    /// "Physical", "Special" or "Status"
    public var category: String
    public var power: Int
    /// 101 means the move never misses.
    public var accuracy: Int
    public var priority: Int

    public init(name: String, type: String, category: String, power: Int,
                accuracy: Int = 100, priority: Int = 0) {
        self.name = name
        self.type = type
        self.category = category
        self.power = power
        self.accuracy = accuracy
        self.priority = priority
    }

    public var isDamaging: Bool { category != "Status" && power > 0 }
}
