import ARKit
import Combine
import RealityKit
import SwiftUI
import TallGrassKit

/// The battle happens on your real floor: once ARKit finds a surface in
/// front of you, a faint ring is placed there with the two creatures facing
/// off, playing their real attack / hit / faint animations. Tap the floor to
/// move the arena.
struct BattleArenaView: UIViewRepresentable {
    let player: BattlePlayer
    let packs: PackStore
    let mySide: String

    func makeCoordinator() -> Coordinator {
        Coordinator(player: player, packs: packs, mySide: mySide)
    }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        config.environmentTexturing = .automatic
        view.session.run(config)
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:))))
        context.coordinator.attach(to: view)
        player.perform = { [weak coordinator = context.coordinator] event in
            await coordinator?.perform(event)
        }
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {}

    static func dismantleUIView(_ view: ARView, coordinator: Coordinator) {
        coordinator.detach()
        view.session.pause()
    }

    @MainActor
    final class Coordinator: NSObject {
        let player: BattlePlayer
        let packs: PackStore
        let mySide: String
        private weak var view: ARView?
        private var updates: Cancellable?
        private var arena: AnchorEntity?
        private var holders: [String: Entity] = [:]
        private var creatures: [String: CreatureModel] = [:]
        private var loading: Set<String> = []

        /// Arena-local spots; the arena's +Z points back at the player.
        private func spot(_ side: String) -> SIMD3<Float> {
            side == mySide ? SIMD3(-0.26, 0, 0.32) : SIMD3(0.26, 0, -0.42)
        }

        private func other(_ side: String) -> String { side == "p1" ? "p2" : "p1" }

        init(player: BattlePlayer, packs: PackStore, mySide: String) {
            self.player = player
            self.packs = packs
            self.mySide = mySide
        }

        func attach(to view: ARView) {
            self.view = view
            updates = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
                MainActor.assumeIsolated { self?.frame() }
            }
        }

        func detach() {
            updates?.cancel()
            updates = nil
        }

        private func frame() {
            guard arena == nil, let view, let frame = view.session.currentFrame,
                  case .normal = frame.camera.trackingState else { return }
            let centre = CGPoint(x: view.bounds.midX, y: view.bounds.midY * 1.15)
            if let hit = view.raycast(from: centre, allowing: .estimatedPlane, alignment: .horizontal).first {
                place(at: hit.worldTransform, camera: frame.camera.transform)
            }
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view, let camera = view.session.currentFrame?.camera else { return }
            let point = gesture.location(in: view)
            if let hit = view.raycast(from: point, allowing: .estimatedPlane, alignment: .horizontal).first {
                place(at: hit.worldTransform, camera: camera.transform)
            }
        }

        private func place(at transform: simd_float4x4, camera: simd_float4x4) {
            let position = SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
            let cameraPosition = SIMD3(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z)
            let toCamera = cameraPosition - position
            let anchor = AnchorEntity(world: position)
            anchor.orientation = simd_quatf(angle: atan2(toCamera.x, toCamera.z), axis: [0, 1, 0])

            if let old = arena {
                // Moving the arena: carry the creatures over.
                for holder in holders.values { anchor.addChild(holder, preservingWorldTransform: false) }
                old.removeFromParent()
            } else {
                anchor.addChild(Self.ring())
            }
            view?.scene.addAnchor(anchor)
            if arena == nil { player.arenaPlaced = true }
            arena = anchor
            // Anyone who was sent out before the floor was found appears now.
            for (side, c) in player.display where holders[side] == nil && !c.fainted {
                Task { await self.sendOut(side: side, species: c.species, shiny: c.shiny) }
            }
        }

        private static func ring() -> Entity {
            var material = UnlitMaterial(color: .white)
            material.blending = .transparent(opacity: 0.22)
            let ring = ModelEntity(mesh: .generateCylinder(height: 0.004, radius: 0.62), materials: [material])
            var inner = UnlitMaterial(color: .white)
            inner.blending = .transparent(opacity: 0.12)
            let line = ModelEntity(mesh: .generateBox(width: 0.01, height: 0.005, depth: 1.1), materials: [inner])
            line.orientation = simd_quatf(angle: .pi / 2, axis: [0, 1, 0])
            ring.addChild(line)
            return ring
        }

        // MARK: Events

        func perform(_ event: BattleController.StageEvent) async {
            switch event {
            case .switchIn(let side, let species, let shiny):
                await sendOut(side: side, species: species, shiny: shiny)
            case .attack(let side, let category):
                await attack(side: side, category: category)
            case .hit(let side, let effective):
                await hit(side: side, effective: effective)
            case .faint(let side):
                await faint(side: side)
            case .celebrate(let side):
                if let c = creatures[side] {
                    let d = c.play("glad")
                    try? await Task.sleep(for: .seconds(min(max(d, 0.8), 2)))
                    c.play("idle", loop: true)
                }
            }
        }

        private func sendOut(side: String, species name: String, shiny: Bool) async {
            guard let arena, !loading.contains(side) else { return }
            loading.insert(side)
            defer { loading.remove(side) }
            holders[side]?.removeFromParent()
            let species = packs.species(named: name)
            let rarity = species?.rarity ?? .common
            let creature = await CreatureModel.load(for: species, name: name, shiny: shiny, rarity: rarity,
                                                    packs: packs, height: CreatureEntity.displayHeight(for: rarity) * 0.75)
            let holder = Entity()
            holder.position = spot(side)
            holder.orientation = CreatureEntity.yaw(from: spot(side), to: spot(other(side)))
            holder.addChild(creature.root)
            creature.root.scale = SIMD3(repeating: 0.01)
            arena.addChild(holder)
            holders[side] = holder
            creatures[side] = creature
            creature.root.move(to: Transform(scale: .one, rotation: creature.root.orientation,
                                             translation: creature.root.position),
                               relativeTo: holder, duration: 0.35, timingFunction: .easeOut)
            let d = creature.play(side == mySide ? "glad" : "roar")
            try? await Task.sleep(for: .seconds(min(max(d, 0.6), 1.6)))
            creature.play("idle", loop: true)
        }

        private func attack(side: String, category: String) async {
            guard let creature = creatures[side], let holder = holders[side] else { return }
            let d = creature.play(category == "Physical" ? "attack" : "special")
            let length = min(max(d, 0.6), 1.8)
            if category == "Physical" {
                // Physical moves close the distance and come back.
                let home = holder.transform
                var lunge = home
                lunge.translation += (spot(other(side)) - home.translation) * 0.35
                holder.move(to: lunge, relativeTo: holder.parent, duration: length * 0.35, timingFunction: .easeIn)
                try? await Task.sleep(for: .seconds(length * 0.45))
                holder.move(to: home, relativeTo: holder.parent, duration: length * 0.35, timingFunction: .easeOut)
                try? await Task.sleep(for: .seconds(length * 0.55))
            } else {
                try? await Task.sleep(for: .seconds(length))
            }
            creature.play("idle", loop: true)
        }

        private func hit(side: String, effective: Double) async {
            guard let creature = creatures[side], let holder = holders[side] else { return }
            let d = creature.play("damage")
            let home = holder.transform
            let amount: Float = effective > 1 ? 0.05 : effective < 1 ? 0.015 : 0.03
            for i in 0..<(effective > 1 ? 4 : 2) {
                var t = home
                t.translation += home.rotation.act(SIMD3(i % 2 == 0 ? amount : -amount, 0, 0))
                holder.move(to: t, relativeTo: holder.parent, duration: 0.05)
                try? await Task.sleep(for: .milliseconds(60))
            }
            holder.move(to: home, relativeTo: holder.parent, duration: 0.05)
            if effective > 1 {
                UINotificationFeedbackGenerator().notificationOccurred(side == mySide ? .error : .success)
            }
            try? await Task.sleep(for: .seconds(min(max(d - 0.25, 0.3), 1)))
            creature.play("idle", loop: true)
        }

        private func faint(side: String) async {
            guard let creature = creatures[side], let holder = holders[side] else { return }
            let d = creature.play("faint", transition: 0.15)
            try? await Task.sleep(for: .seconds(min(max(d, 0.5), 1.6)))
            var gone = holder.transform
            gone.scale = SIMD3(repeating: 0.01)
            gone.translation.y -= 0.1
            holder.move(to: gone, relativeTo: holder.parent, duration: 0.45, timingFunction: .easeIn)
            try? await Task.sleep(for: .milliseconds(480))
            holder.removeFromParent()
            holders[side] = nil
            creatures[side] = nil
        }
    }
}

