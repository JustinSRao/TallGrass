import RealityKit
import SwiftUI
import TallGrassKit
import UIKit

/// A small 3D arena (no camera feed) where the two active creatures face
/// off. It replays the controller's stage events one after another: send-outs,
/// attack lunges, hit flashes and faints.
struct BattleStageView: UIViewRepresentable {
    let battle: BattleController
    let packs: PackStore

    func makeCoordinator() -> Coordinator {
        Coordinator(battle: battle, packs: packs)
    }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        view.environment.background = .color(UIColor(red: 0.55, green: 0.75, blue: 0.95, alpha: 1))
        context.coordinator.build(in: view)
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        context.coordinator.sync()
    }

    @MainActor
    final class Coordinator {
        let battle: BattleController
        let packs: PackStore
        private let anchor = AnchorEntity(world: SIMD3<Float>(0, 0, 0))
        private var slots: [String: Entity] = [:]        // side -> holder
        private var played = 0
        private var queue: [BattleController.StageEvent] = []
        private var busy = false

        private let spots: [String: SIMD3<Float>] = ["near": [-0.55, 0, 0.45], "far": [0.55, 0, -0.55]]

        init(battle: BattleController, packs: PackStore) {
            self.battle = battle
            self.packs = packs
        }

        private func spot(for side: String) -> SIMD3<Float> {
            side == battle.mySide ? spots["near"]! : spots["far"]!
        }

        func build(in view: ARView) {
            view.scene.addAnchor(anchor)

            let ground = ModelEntity(mesh: .generatePlane(width: 4, depth: 4),
                                     materials: [SimpleMaterial(color: UIColor(red: 0.45, green: 0.7, blue: 0.35, alpha: 1), isMetallic: false)])
            anchor.addChild(ground)
            for side in ["near", "far"] {
                let pad = ModelEntity(mesh: .generateCylinder(height: 0.02, radius: 0.42),
                                      materials: [SimpleMaterial(color: UIColor(white: 0.92, alpha: 1), isMetallic: false)])
                pad.position = spots[side]! + [0, 0.01, 0]
                anchor.addChild(pad)
            }

            let sun = DirectionalLight()
            sun.light.intensity = 3000
            sun.look(at: .zero, from: [1.5, 3, 2], relativeTo: nil)
            anchor.addChild(sun)

            let camera = PerspectiveCamera()
            camera.camera.fieldOfViewInDegrees = 50
            camera.look(at: [0, 0.35, -0.05], from: [-0.35, 1.05, 2.15], relativeTo: nil)
            anchor.addChild(camera)
        }

        func sync() {
            let events = battle.stageEvents
            guard events.count > played else { return }
            queue.append(contentsOf: events[played...])
            played = events.count
            playNext()
        }

        private func playNext() {
            guard !busy, !queue.isEmpty else { return }
            busy = true
            let event = queue.removeFirst()
            Task { @MainActor in
                await play(event)
                busy = false
                playNext()
            }
        }

        private func play(_ event: BattleController.StageEvent) async {
            switch event {
            case .switchIn(let side, let speciesName):
                slots[side]?.removeFromParent()
                let species = packs.species(named: speciesName)
                let holder = Entity()
                holder.position = spot(for: side)
                let other = spot(for: side == "p1" ? "p2" : "p1")
                holder.orientation = CreatureEntity.yaw(from: holder.position, to: other)
                let model = await CreatureEntity.make(for: species, name: speciesName, shiny: false,
                                                      rarity: species?.rarity ?? .common, packs: packs, height: 0.75)
                holder.addChild(model)
                holder.scale = SIMD3(repeating: 0.01)
                anchor.addChild(holder)
                slots[side] = holder
                holder.move(to: Transform(scale: .one, rotation: holder.orientation, translation: holder.position),
                            relativeTo: anchor, duration: 0.35, timingFunction: .easeOut)
                try? await Task.sleep(for: .milliseconds(450))
            case .attack(let side):
                guard let holder = slots[side] else { return }
                let home = holder.transform
                let target = spot(for: side == "p1" ? "p2" : "p1")
                var lunge = home
                lunge.translation += (target - home.translation) * 0.3
                holder.move(to: lunge, relativeTo: anchor, duration: 0.15, timingFunction: .easeIn)
                try? await Task.sleep(for: .milliseconds(170))
                holder.move(to: home, relativeTo: anchor, duration: 0.2, timingFunction: .easeOut)
                try? await Task.sleep(for: .milliseconds(220))
            case .hit(let side, let effective):
                guard let holder = slots[side] else { return }
                let home = holder.transform
                let shakes = effective > 1 ? 4 : 2
                let amount: Float = effective > 1 ? 0.07 : effective < 1 ? 0.02 : 0.04
                for i in 0..<shakes {
                    var t = home
                    t.translation.x += (i % 2 == 0 ? amount : -amount)
                    holder.move(to: t, relativeTo: anchor, duration: 0.05)
                    try? await Task.sleep(for: .milliseconds(60))
                }
                holder.move(to: home, relativeTo: anchor, duration: 0.05)
                if effective > 1 {
                    UINotificationFeedbackGenerator().notificationOccurred(side == battle.mySide ? .error : .success)
                }
                try? await Task.sleep(for: .milliseconds(150))
            case .faint(let side):
                guard let holder = slots[side] else { return }
                var gone = holder.transform
                gone.translation.y -= 0.4
                gone.scale = SIMD3(repeating: 0.01)
                holder.move(to: gone, relativeTo: anchor, duration: 0.6, timingFunction: .easeIn)
                try? await Task.sleep(for: .milliseconds(650))
                holder.removeFromParent()
                slots[side] = nil
            }
        }
    }
}
