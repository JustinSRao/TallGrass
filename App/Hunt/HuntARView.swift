import ARKit
import Combine
import RealityKit
import SwiftUI
import TallGrassKit

/// The camera view. Places each visible spawn in the room relative to where
/// the player stood when tracking started, keeps them in sync with the hunt,
/// and turns taps into throws.
struct HuntARView: UIViewRepresentable {
    let model: HuntModel
    let packs: PackStore

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, packs: packs)
    }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        config.environmentTexturing = .automatic
        view.session.run(config)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {}

    static func dismantleUIView(_ view: ARView, coordinator: Coordinator) {
        coordinator.detach()
        view.session.pause()
    }

    @MainActor
    final class Coordinator: NSObject {
        let model: HuntModel
        let packs: PackStore
        private weak var view: ARView?
        private var updates: Cancellable?
        private var origin: simd_float4x4?
        private var placed: [Int: Entity] = [:]
        private let root = AnchorEntity(world: SIMD3<Float>(0, 0, 0))

        /// Assumed phone height above the floor until a real floor is found.
        private static let handHeight: Float = 1.4

        init(model: HuntModel, packs: PackStore) {
            self.model = model
            self.packs = packs
        }

        func attach(to view: ARView) {
            self.view = view
            view.scene.addAnchor(root)
            updates = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
                MainActor.assumeIsolated { self?.frame() }
            }
        }

        func detach() {
            updates?.cancel()
            updates = nil
        }

        // MARK: Per-frame sync

        private func frame() {
            guard let view, let camera = view.session.currentFrame?.camera,
                  case .normal = camera.trackingState else { return }
            if origin == nil { origin = camera.transform }
            guard let origin else { return }

            let visible = model.visible
            let visibleIDs = Set(visible.map(\.id))
            for (id, entity) in placed where !visibleIDs.contains(id) {
                entity.removeFromParent()
                placed[id] = nil
            }
            for spawn in visible where placed[spawn.id] == nil {
                place(spawn, origin: origin, in: view)
            }
        }

        private func place(_ spawn: Spawn, origin: simd_float4x4, in view: ARView) {
            let holder = Entity()
            holder.name = "spawn-\(spawn.id)"
            holder.position = position(for: spawn, origin: origin, in: view)
            root.addChild(holder)
            placed[spawn.id] = holder

            let species = model.species(for: spawn)
            guard let species, let url = packs.modelURL(for: species) else {
                holder.addChild(Self.placeholder(for: spawn, name: species?.name ?? "?"))
                holder.generateCollisionShapes(recursive: true)
                return
            }
            Task { [weak self] in
                let loaded = try? await Entity(contentsOf: url)
                guard let self, self.placed[spawn.id] === holder else { return }
                if let loaded {
                    Self.fit(loaded, rarity: spawn.rarity)
                    holder.addChild(loaded)
                } else {
                    holder.addChild(Self.placeholder(for: spawn, name: species.name))
                }
                holder.generateCollisionShapes(recursive: true)
            }
        }

        private func position(for spawn: Spawn, origin: simd_float4x4, in view: ARView) -> SIMD3<Float> {
            let start = SIMD3(origin.columns.3.x, origin.columns.3.y, origin.columns.3.z)
            let flatForward = SIMD3(-origin.columns.2.x, 0, -origin.columns.2.z)
            let forward = simd_length(flatForward) > 0.001 ? simd_normalize(flatForward) : SIMD3<Float>(0, 0, -1)
            // Bearing is clockwise seen from above, i.e. a negative turn about +y.
            let turn = simd_quatf(angle: -Float(spawn.bearing * .pi / 180), axis: SIMD3<Float>(0, 1, 0))
            var p = start + turn.act(forward) * Float(spawn.distance)
            p.y = floorHeight(below: SIMD3(p.x, start.y, p.z), in: view) ?? (start.y - Self.handHeight)
            p.y += Float(spawn.height)
            return p
        }

        private func floorHeight(below point: SIMD3<Float>, in view: ARView) -> Float? {
            let query = ARRaycastQuery(origin: point, direction: SIMD3<Float>(0, -1, 0),
                                       allowing: .estimatedPlane, alignment: .horizontal)
            return view.session.raycast(query).first?.worldTransform.columns.3.y
        }

        // MARK: Throwing

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view else { return }
            let point = gesture.location(in: view)
            guard var entity = view.entity(at: point) else { return }
            while !entity.name.hasPrefix("spawn-"), let parent = entity.parent {
                entity = parent
            }
            guard entity.name.hasPrefix("spawn-"), let id = Int(entity.name.dropFirst("spawn-".count)) else { return }

            // Aim: how close to the middle of the screen the creature is.
            let onScreen = view.project(entity.position(relativeTo: nil)) ?? point
            let half = min(view.bounds.width, view.bounds.height) / 2
            let offCentre = hypot(onScreen.x - view.bounds.midX, onScreen.y - view.bounds.midY) / max(half, 1)
            model.throwAt(spawnID: id, quality: Double(max(0, 1 - offCentre)))
        }

        // MARK: Visuals

        /// Scales a pack model to a sensible real-world size with its feet on the floor.
        private static func fit(_ entity: Entity, rarity: Rarity) {
            let target: Float = rarity >= .epic ? 1.2 : 0.6
            let height = entity.visualBounds(relativeTo: nil).extents.y
            if height > 0 { entity.scale *= SIMD3(repeating: target / height) }
            let bottom = entity.visualBounds(relativeTo: nil).min.y
            entity.position.y -= bottom
        }

        /// A coloured orb with a name tag, used when a species has no model.
        private static func placeholder(for spawn: Spawn, name: String) -> Entity {
            let radius: Float = 0.15
            let orb = ModelEntity(mesh: .generateSphere(radius: radius),
                                  materials: [SimpleMaterial(color: color(for: spawn), isMetallic: spawn.isShiny)])
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

        private static func color(for spawn: Spawn) -> UIColor {
            if spawn.isShiny { return .systemYellow }
            switch spawn.rarity {
            case .common: return .systemGreen
            case .uncommon: return .systemTeal
            case .rare: return .systemBlue
            case .epic: return .systemPurple
            case .legendary: return .systemOrange
            }
        }
    }
}
