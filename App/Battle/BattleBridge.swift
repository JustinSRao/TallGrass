import Foundation
import JavaScriptCore
import TallGrassKit

/// Runs the bundled Showdown simulator (BattleEngine/, built into
/// battle-engine.js) inside JavaScriptCore. All data crosses as JSON.
///
/// The engine is deterministic: the same seed and the same choices in the
/// same order give the same battle on every device. Two-phone battles rely
/// on that, sending only choices between phones.
final class BattleBridge {
    enum BridgeError: Error, CustomStringConvertible {
        case missingEngine
        case javaScript(String)

        var description: String {
            switch self {
            case .missingEngine: "battle-engine.js is missing from the app bundle (run `npm run build` in BattleEngine/)"
            case .javaScript(let message): "Battle engine error: \(message)"
            }
        }
    }

    private let context: JSContext
    private var lastException: String?

    init(bundle: Bundle = .main) throws {
        guard let url = bundle.url(forResource: "battle-engine", withExtension: "js"),
              let code = try? String(contentsOf: url, encoding: .utf8) else {
            throw BridgeError.missingEngine
        }
        guard let context = JSContext() else { throw BridgeError.javaScript("could not create a JSContext") }
        self.context = context
        context.exceptionHandler = { [weak self] _, exception in
            self?.lastException = exception?.toString() ?? "unknown error"
        }
        context.evaluateScript(code, withSourceURL: url)
        if let error = lastException { throw BridgeError.javaScript(error) }
    }

    func start(seed: [UInt16], p1: (name: String, team: [BattleMon]), p2: (name: String, team: [BattleMon])) throws -> BattleUpdate {
        struct Side: Encodable { let name: String; let team: [BattleMon] }
        struct Start: Encodable { let seed: [UInt16]; let p1: Side; let p2: Side }
        let json = try String(decoding: JSONEncoder().encode(
            Start(seed: seed, p1: Side(name: p1.name, team: p1.team), p2: Side(name: p2.name, team: p2.team))),
            as: UTF8.self)
        return try decode(call("start", [json]))
    }

    func choose(battle id: Int, side: String, choice: String) throws -> BattleUpdate {
        try decode(call("choose", [id, side, choice]))
    }

    func end(battle id: Int) {
        _ = try? call("end", [id])
    }

    private var moveCache: [String: MoveInfo] = [:]

    /// Type, category, power and accuracy of a move, from Showdown's data.
    func moveInfo(_ name: String) -> MoveInfo? {
        if let cached = moveCache[name] { return cached }
        guard let json = try? call("moveInfo", [name]),
              let info = try? JSONDecoder().decode(MoveInfo?.self, from: Data(json.utf8)) else { return nil }
        moveCache[name] = info
        return info
    }

    /// Type-chart multiplier of `move` against `species` (nil for status moves).
    func effectiveness(move: String, against species: String) -> Double? {
        guard let json = try? call("effectiveness", [move, species]) else { return nil }
        return try? JSONDecoder().decode(Double?.self, from: Data(json.utf8))
    }

    private func call(_ function: String, _ arguments: [Any]) throws -> String {
        lastException = nil
        let api = context.objectForKeyedSubscript("TallGrassBattle")
        let result = api?.invokeMethod(function, withArguments: arguments)
        if let error = lastException { throw BridgeError.javaScript(error) }
        return result?.toString() ?? ""
    }

    private func decode(_ json: String) throws -> BattleUpdate {
        try JSONDecoder().decode(BattleUpdate.self, from: Data(json.utf8))
    }
}

// MARK: - Engine messages (the parts the app uses)

struct MoveInfo: Decodable, Equatable {
    var name: String
    var type: String
    var category: String   // "Physical", "Special", "Status"
    var basePower: Int
    /// nil means the move never misses (Showdown sends `true`).
    var accuracy: Int?
    var pp: Int
    var priority: Int

    enum CodingKeys: String, CodingKey { case name, type, category, basePower, accuracy, pp, priority }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decode(String.self, forKey: .type)
        category = try c.decode(String.self, forKey: .category)
        basePower = try c.decodeIfPresent(Int.self, forKey: .basePower) ?? 0
        accuracy = try? c.decode(Int.self, forKey: .accuracy)
        pp = try c.decodeIfPresent(Int.self, forKey: .pp) ?? 0
        priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 0
    }
}

struct BattleUpdate: Decodable {
    var id: Int?
    var events: [String]
    var requests: [String: BattleRequest?]
    var winner: String?
    var error: String?
}

struct BattleRequest: Decodable {
    var wait: Bool?
    var teamPreview: Bool?
    var forceSwitch: [Bool]?
    var active: [ActiveRequest]?
    var side: SideRequest

    struct ActiveRequest: Decodable {
        var moves: [MoveSlot]
        var trapped: Bool?
    }

    struct MoveSlot: Decodable {
        var move: String
        var pp: Int?
        var maxpp: Int?
        var disabled: Bool

        enum CodingKeys: String, CodingKey { case move, pp, maxpp, disabled }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            move = try c.decode(String.self, forKey: .move)
            pp = try c.decodeIfPresent(Int.self, forKey: .pp)
            maxpp = try c.decodeIfPresent(Int.self, forKey: .maxpp)
            // Showdown sends `disabled` as a bool or as the name of what disabled it.
            if let flag = try? c.decodeIfPresent(Bool.self, forKey: .disabled) {
                disabled = flag
            } else {
                disabled = (try? c.decodeIfPresent(String.self, forKey: .disabled)) != nil
            }
        }
    }

    struct SideRequest: Decodable {
        var name: String
        var id: String
        var pokemon: [SidePokemon]
    }

    struct SidePokemon: Decodable {
        var ident: String
        var details: String
        var condition: String
        var active: Bool

        var name: String { ident.components(separatedBy: ": ").last ?? ident }
        var isFainted: Bool { condition.hasSuffix(" fnt") }
    }

    var isActionable: Bool { wait != true }

    /// Every legal choice string for this request, in Showdown's syntax.
    var legalChoices: [String] {
        if teamPreview == true { return ["default"] }
        let switches = side.pokemon.enumerated()
            .filter { !$0.element.active && !$0.element.isFainted }
            .map { "switch \($0.offset + 1)" }
        if forceSwitch?.contains(true) == true { return switches.isEmpty ? ["pass"] : switches }
        guard let active = active?.first else { return ["default"] }
        let moves = active.moves.enumerated()
            .filter { !$0.element.disabled && ($0.element.pp ?? 1) > 0 }
            .map { "move \($0.offset + 1)" }
        let all = (moves.isEmpty ? ["move 1"] : moves) + (active.trapped == true ? [] : switches)
        return all
    }
}
