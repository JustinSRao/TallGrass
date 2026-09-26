import Foundation
import RealityKit
import TallGrassKit
import UIKit

/// Sidecar written next to each pack model by the pipeline
/// (`models/<key>.json`): clip time ranges and the material order per mesh.
struct ModelMeta: Decodable {
    struct Clip: Decodable {
        var name: String
        var startTime: Double
        var endTime: Double
    }
    var fps: Double
    var clips: [Clip]
    var meshes: [String: [String]]
    var height: Double
}

/// A creature in the world: the pack's animated model (or a placeholder orb),
/// scaled to a friendly size, standing on its origin and facing +Z.
///
/// Clips are addressed by role: "idle", "walk", "run", "attack", "special",
/// "damage", "faint", "glad", "notice", "roar", "eat", "rest", "sleep".
/// Not every species has every role; `play` falls back sensibly.
@MainActor
final class CreatureModel {
    let root = Entity()
    let height: Float
    private let animated: Entity?
    private let source: AnimationDefinition?
    private let clips: [String: ModelMeta.Clip]
    private let frameTime: Double
    private(set) var currentClip: String?
    private var controller: AnimationPlaybackController?

    private init(content: Entity, height: Float, animated: Entity?, meta: ModelMeta?) {
        self.height = height
        self.animated = animated
        source = animated?.availableAnimations.first?.definition
        clips = Dictionary((meta?.clips ?? []).map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        frameTime = 1 / (meta?.fps ?? 30)
        root.addChild(content)
    }

    var isAnimated: Bool { source != nil && !clips.isEmpty }

    func has(_ role: String) -> Bool { source != nil && clips[role] != nil }

    func duration(of role: String) -> TimeInterval {
        guard let clip = clips[resolve(role)] else { return 0 }
        return clip.endTime - clip.startTime + frameTime
    }

    /// Plays a clip by role and returns its length in seconds (0 if none).
    @discardableResult
    func play(_ role: String, loop: Bool = false, transition: TimeInterval = 0.25, speed: Float = 1) -> TimeInterval {
        let role = resolve(role)
        guard let source, let animated, let clip = clips[role] else { return 0 }
        if loop, currentClip == role, controller?.isPlaying == true { return duration(of: role) }
        let view = AnimationView(source: source, name: role,
                                 trimStart: clip.startTime, trimEnd: clip.endTime + frameTime, speed: speed)
        guard let resource = try? AnimationResource.generate(with: view) else { return 0 }
        controller = animated.playAnimation(loop ? resource.repeat() : resource,
                                            transitionDuration: transition, startsPaused: false)
        currentClip = role
        return duration(of: role) / Double(max(speed, 0.01))
    }

    /// Falls back to a related clip when a species lacks the one asked for.
    private func resolve(_ role: String) -> String {
        if clips[role] != nil { return role }
        let fallbacks: [String: [String]] = [
            "run": ["walk"], "special": ["attack", "roar"], "attack": ["special", "roar"],
            "glad": ["roar", "notice"], "notice": ["roar", "glad"], "roar": ["glad", "notice"],
            "eat": ["rest", "idle"], "rest": ["sleep", "idle"], "sleep": ["rest", "idle"],
            "faint": ["damage"], "damage": ["notice"], "walk": ["idle"],
        ]
        return fallbacks[role]?.first { clips[$0] != nil } ?? "idle"
    }

    // MARK: Loading

    static func load(for species: CreatureSpecies?, name: String, shiny: Bool, rarity: Rarity,
                     packs: PackStore, height: Float? = nil) async -> CreatureModel {
        let target = height ?? CreatureEntity.displayHeight(for: rarity)
        guard let species, let url = packs.modelURL(for: species),
              let model = try? await Entity(contentsOf: url) else {
            let orb = CreatureEntity.placeholder(name: name, rarity: rarity, shiny: shiny, height: target)
            return CreatureModel(content: orb, height: target, animated: nil, meta: nil)
        }
        let meta = packs.modelMeta(for: species)
        // Scale from the height measured at conversion time: bounds of a
        // skinned, animating model are unreliable.
        let natural = Float(meta?.height ?? 0)
        if natural > 0.001 {
            model.scale = SIMD3(repeating: target / natural)
        } else {
            CreatureEntity.fit(model, height: target)
        }
        if shiny, let meta { await applyShiny(to: model, species: species, meta: meta, packs: packs) }
        let animated = findAnimated(in: model)
        let creature = CreatureModel(content: model, height: target, animated: animated, meta: meta)
        creature.root.generateCollisionShapes(recursive: true)
        creature.play("idle", loop: true, transition: 0)
        return creature
    }

    private static func findAnimated(in entity: Entity) -> Entity? {
        if !entity.availableAnimations.isEmpty { return entity }
        for child in entity.children {
            if let found = findAnimated(in: child) { return found }
        }
        return nil
    }

    /// Shiny variants ship as textures only; swap them onto matching materials.
    private static func applyShiny(to root: Entity, species: CreatureSpecies, meta: ModelMeta, packs: PackStore) async {
        var cache: [String: TextureResource] = [:]
        var stack: [Entity] = [root]
        while let entity = stack.popLast() {
            stack.append(contentsOf: entity.children)
            guard var model = entity.components[ModelComponent.self] else { continue }
            let names = meta.meshes[entity.name] ?? meta.meshes[entity.name + "_shape"]
                ?? entity.parent.flatMap { meta.meshes[$0.name] ?? meta.meshes[$0.name + "_shape"] }
            guard let names, names.count == model.materials.count else { continue }
            var changed = false
            for (i, materialName) in names.enumerated() {
                let stem = materialName.hasPrefix("tg_") ? String(materialName.dropFirst(3)) : materialName
                guard let url = packs.shinyTextureURL(for: species, stem: stem),
                      var material = model.materials[i] as? PhysicallyBasedMaterial else { continue }
                let texture: TextureResource
                if let cached = cache[stem] {
                    texture = cached
                } else if let loaded = try? TextureResource.load(contentsOf: url) {
                    cache[stem] = loaded
                    texture = loaded
                } else { continue }
                material.baseColor = .init(tint: .white, texture: .init(texture))
                model.materials[i] = material
                changed = true
            }
            if changed { entity.components.set(model) }
        }
    }
}

/// Shared creature helpers: sizes, colours, placeholder, facing.
@MainActor
enum CreatureEntity {
    /// Real creatures vary from 0.3 m to 5 m; in a room that's unplayable, so
    /// sizes are squashed into a friendly range, with rarer ones a bit bigger.
    static func displayHeight(for rarity: Rarity) -> Float {
        switch rarity {
        case .common: 0.45
        case .uncommon: 0.55
        case .rare: 0.7
        case .epic: 0.9
        case .legendary: 1.2
        }
    }

    /// Scales `entity` to `height` metres tall with its lowest point at y = 0.
    static func fit(_ entity: Entity, height: Float) {
        let bounds = entity.visualBounds(relativeTo: entity.parent)
        if bounds.extents.y > 0.0001 {
            entity.scale *= SIMD3(repeating: height / bounds.extents.y)
        }
        let after = entity.visualBounds(relativeTo: entity.parent)
        entity.position -= SIMD3(after.center.x, after.min.y, after.center.z)
    }

    static func color(for rarity: Rarity, shiny: Bool) -> UIColor {
        if shiny { return .systemYellow }
        switch rarity {
        case .common: return .systemGreen
        case .uncommon: return .systemTeal
        case .rare: return .systemBlue
        case .epic: return .systemPurple
        case .legendary: return .systemOrange
        }
    }

    static func placeholder(name: String, rarity: Rarity, shiny: Bool, height: Float?) -> Entity {
        let radius: Float = (height ?? displayHeight(for: rarity)) * 0.3
        let orb = ModelEntity(mesh: .generateSphere(radius: radius),
                              materials: [SimpleMaterial(color: color(for: rarity, shiny: shiny), isMetallic: shiny)])
        orb.position.y = radius
        let text = ModelEntity(mesh: .generateText(name, extrusionDepth: 0.005, font: .systemFont(ofSize: 0.07),
                                                   containerFrame: .zero, alignment: .center,
                                                   lineBreakMode: .byWordWrapping),
                               materials: [SimpleMaterial(color: .white, isMetallic: false)])
        let width = text.visualBounds(relativeTo: nil).extents.x
        text.position = SIMD3(-width / 2, radius * 2 + 0.05, 0)
        let group = Entity()
        group.addChild(orb)
        group.addChild(text)
        return group
    }

    /// Rotation that turns something facing +Z at `from` toward `to` (yaw only).
    static func yaw(from: SIMD3<Float>, to: SIMD3<Float>) -> simd_quatf {
        let d = to - from
        return simd_quatf(angle: atan2(d.x, d.z), axis: [0, 1, 0])
    }
}
