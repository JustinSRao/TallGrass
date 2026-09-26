import Foundation
import RealityKit
import TallGrassKit
import UIKit

/// Builds the 3D entity for a creature: the pack's USDZ model when there is
/// one (shiny variant when rolled), otherwise a coloured orb with a name tag.
///
/// The returned entity stands on its local origin and faces +Z, so callers
/// only have to position it and turn it toward whatever it should look at.
@MainActor
enum CreatureEntity {
    /// Pack models are exported facing Blender's front, which arrives in
    /// RealityKit facing +Z. If a future exporter changes that, fix it here.
    static let modelYawCorrection: Float = 0

    static func make(for species: CreatureSpecies?, name: String, shiny: Bool, rarity: Rarity,
                     packs: PackStore, height: Float? = nil) async -> Entity {
        let root = Entity()
        if let species, let url = packs.modelURL(for: species, shiny: shiny),
           let model = try? await Entity(contentsOf: url) {
            let target = height ?? displayHeight(for: rarity)
            fit(model, height: target)
            model.orientation = simd_quatf(angle: modelYawCorrection, axis: [0, 1, 0])
            root.addChild(model)
        } else {
            root.addChild(placeholder(name: name, rarity: rarity, shiny: shiny, height: height))
        }
        root.generateCollisionShapes(recursive: true)
        return root
    }

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
        let current = bounds.extents.y
        if current > 0.0001 {
            entity.scale *= SIMD3(repeating: height / current)
        }
        let after = entity.visualBounds(relativeTo: entity.parent)
        entity.position.y -= after.min.y
        entity.position.x -= after.center.x
        entity.position.z -= after.center.z
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

        let text = ModelEntity(mesh: .generateText(name, extrusionDepth: 0.005,
                                                   font: .systemFont(ofSize: 0.07),
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

    /// Yaw that turns an entity at `from` (facing +Z) to look at `to`.
    static func yaw(from: SIMD3<Float>, to: SIMD3<Float>) -> simd_quatf {
        let d = to - from
        return simd_quatf(angle: atan2(d.x, d.z), axis: [0, 1, 0])
    }
}
