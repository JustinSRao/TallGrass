import ARKit
import Combine
import QuartzCore
import RealityKit
import SwiftUI
import TallGrassKit

/// The camera view. Places each visible spawn in the room relative to where
/// the player stood when tracking started, keeps creatures facing the player
/// (rarer ones wander), and turns swipes into ball throws with a capture
/// sequence.
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
        view.addGestureRecognizer(UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:))))
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:))))
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
        private struct Placed {
            let holder: Entity
            let spawn: Spawn
            var base: SIMD3<Float>
            let phase: Float
            var busy = false
        }

        private struct Flight {
            let ball: Entity
            let start: CFTimeInterval
            let duration: Double
            let from: SIMD3<Float>
            let to: SIMD3<Float>
            let apex: Float
            let targetID: Int?
            let quality: Double
        }

        let model: HuntModel
        let packs: PackStore
        private weak var view: ARView?
        private var updates: Cancellable?
        private var origin: simd_float4x4?
        private var placed: [Int: Placed] = [:]
        private var flights: [Flight] = []
        private var lastIndicatorUpdate: CFTimeInterval = 0
        private var panStart: CGPoint = .zero
        private let root = AnchorEntity(world: SIMD3<Float>(0, 0, 0))

        /// Assumed phone height above the floor until a real floor is found.
        private static let handHeight: Float = 1.4
        private static let ballRadius: Float = 0.035

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

        // MARK: Per-frame

        private func frame() {
            guard let view, let camera = view.session.currentFrame?.camera else { return }
            let now = CACurrentMediaTime()
            updateFlights(now: now)

            guard case .normal = camera.trackingState else { return }
            if origin == nil { origin = camera.transform }
            guard let origin else { return }

            let visible = model.visible
            let visibleIDs = Set(visible.map(\.id))
            for (id, p) in placed where !visibleIDs.contains(id) && !p.busy {
                p.holder.removeFromParent()
                placed[id] = nil
            }
            for spawn in visible where placed[spawn.id] == nil {
                place(spawn, origin: origin, in: view)
            }

            let cam = SIMD3(camera.transform.columns.3.x, camera.transform.columns.3.y, camera.transform.columns.3.z)
            let t = Float(now)
            for (_, p) in placed where !p.busy {
                let amplitude = Self.wander(for: p.spawn.rarity)
                var pos = p.base
                if amplitude > 0 {
                    pos.x += amplitude * sin(t * 0.35 + p.phase)
                    pos.z += amplitude * cos(t * 0.27 + p.phase * 1.7)
                }
                pos.y += 0.012 * sin(t * 2.2 + p.phase) + (p.spawn.height > 0 ? 0.05 * sin(t * 1.3 + p.phase) : 0)
                p.holder.position = pos
                p.holder.orientation = CreatureEntity.yaw(from: pos, to: cam)
            }

            if now - lastIndicatorUpdate > 0.2 {
                lastIndicatorUpdate = now
                updateIndicators(in: view, camera: camera)
            }
        }

        private static func wander(for rarity: Rarity) -> Float {
            switch rarity {
            case .common: 0
            case .uncommon: 0.08
            case .rare: 0.18
            case .epic: 0.3
            case .legendary: 0.45
            }
        }

        private func place(_ spawn: Spawn, origin: simd_float4x4, in view: ARView) {
            let holder = Entity()
            holder.name = "spawn-\(spawn.id)"
            let base = position(for: spawn, origin: origin, in: view)
            holder.position = base
            root.addChild(holder)
            placed[spawn.id] = Placed(holder: holder, spawn: spawn, base: base, phase: Float(spawn.id) * 1.37)

            let species = model.species(for: spawn)
            Task { [weak self] in
                guard let self else { return }
                let creature = await CreatureEntity.make(for: species, name: species?.name ?? "?",
                                                         shiny: spawn.isShiny, rarity: spawn.rarity, packs: self.packs)
                guard self.placed[spawn.id]?.holder === holder else { return }
                // Pop in. Animate the child: the holder's position is driven every frame.
                creature.scale = SIMD3(repeating: 0.01)
                holder.addChild(creature)
                holder.generateCollisionShapes(recursive: true)
                creature.move(to: Transform(scale: .one, rotation: creature.orientation, translation: creature.position),
                              relativeTo: holder, duration: 0.3, timingFunction: .easeOut)
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

        // MARK: Off-screen hints

        private func updateIndicators(in view: ARView, camera: ARCamera) {
            let toCamera = camera.transform.inverse
            let bounds = view.bounds.insetBy(dx: 30, dy: 60)
            var result: [HuntModel.Indicator] = []
            for (id, p) in placed where !p.busy {
                let world = p.holder.position(relativeTo: nil) + [0, 0.2, 0]
                if let screen = view.project(world), bounds.contains(screen) {
                    // Only on screen if it's actually in front of the camera.
                    let local = toCamera * SIMD4(world, 1)
                    if local.z < 0 { continue }
                }
                let local = toCamera * SIMD4(world, 1)
                // Camera space: +x right, +y up, -z forward. Screen angle: 0 = right, π/2 = down.
                var angle = atan2(Double(-local.y), Double(local.x))
                if local.z > 0, abs(local.x) < 0.2 { angle = .pi / 2 }   // straight behind: point down ("turn around")
                result.append(.init(id: id, angle: angle, rarity: p.spawn.rarity))
            }
            if result != model.indicators { model.indicators = result }
        }

        // MARK: Throwing

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let view else { return }
            switch gesture.state {
            case .began:
                panStart = gesture.location(in: view)
            case .ended:
                let end = gesture.location(in: view)
                let velocity = gesture.velocity(in: view)
                let drag = CGVector(dx: end.x - panStart.x, dy: end.y - panStart.y)
                guard drag.dy < -40 else { return }   // throws go up the screen
                throwBall(from: panStart, direction: drag, speed: hypot(velocity.x, velocity.y), in: view)
            default:
                break
            }
        }

        /// A tap lobs a gentle, less accurate throw at whatever was tapped.
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view else { return }
            let point = gesture.location(in: view)
            guard var entity = view.entity(at: point) else { return }
            while !entity.name.hasPrefix("spawn-"), let parent = entity.parent { entity = parent }
            guard entity.name.hasPrefix("spawn-"), let id = Int(entity.name.dropFirst("spawn-".count)),
                  let p = placed[id], !p.busy else { return }
            let onScreen = view.project(p.holder.position(relativeTo: nil)) ?? point
            let half = min(view.bounds.width, view.bounds.height) / 2
            let centred = 1 - min(1, hypot(onScreen.x - view.bounds.midX, onScreen.y - view.bounds.midY) / max(half, 1))
            launch(toward: id, quality: Double(centred) * 0.5, in: view)
        }

        private func throwBall(from start: CGPoint, direction: CGVector, speed: CGFloat, in view: ARView) {
            let length = max(1, hypot(direction.dx, direction.dy))
            let dir = CGVector(dx: direction.dx / length, dy: direction.dy / length)
            guard let camera = view.session.currentFrame?.camera else { return }
            let camPos = SIMD3(camera.transform.columns.3.x, camera.transform.columns.3.y, camera.transform.columns.3.z)

            // Target: the creature whose on-screen position best matches the swipe direction.
            let maxAngle = 22.0 * Double.pi / 180
            var best: (id: Int, angle: Double, distance: Float)?
            for (id, p) in placed where !p.busy {
                let world = p.holder.position(relativeTo: nil) + [0, 0.25, 0]
                guard let screen = view.project(world) else { continue }
                let v = CGVector(dx: screen.x - start.x, dy: screen.y - start.y)
                let vl = hypot(v.dx, v.dy)
                guard vl > 1 else { continue }
                let cosine = max(-1, min(1, (v.dx * dir.dx + v.dy * dir.dy) / vl))
                let angle = acos(Double(cosine))
                if angle < maxAngle, angle < (best?.angle ?? .infinity) {
                    best = (id, angle, simd_distance(camPos, world))
                }
            }

            guard let target = best else {
                launchMiss(direction: dir, in: view)
                model.missed()
                return
            }
            // Aim counts most; power should roughly match the distance.
            let aim = 1 - target.angle / maxAngle
            let needed = 900 + 250 * Double(target.distance)
            let ratio = Double(speed) / needed
            if ratio < 0.4 {
                launchMiss(direction: dir, in: view, short: true)
                model.missed()
                return
            }
            let power = max(0, 1 - abs(ratio - 1) * 1.2)
            launch(toward: target.id, quality: 0.7 * aim + 0.3 * power, in: view)
        }

        private func makeBall() -> Entity {
            let ball = Entity()
            let top = ModelEntity(mesh: .generateSphere(radius: Self.ballRadius),
                                  materials: [SimpleMaterial(color: .systemRed, isMetallic: false)])
            let band = ModelEntity(mesh: .generateCylinder(height: 0.008, radius: Self.ballRadius * 1.04),
                                   materials: [SimpleMaterial(color: .white, isMetallic: false)])
            let button = ModelEntity(mesh: .generateSphere(radius: Self.ballRadius * 0.3),
                                     materials: [SimpleMaterial(color: .white, isMetallic: false)])
            button.position = [0, 0, Self.ballRadius * 0.9]
            ball.addChild(top)
            ball.addChild(band)
            ball.addChild(button)
            return ball
        }

        private func handPosition(_ view: ARView) -> SIMD3<Float>? {
            guard let camera = view.session.currentFrame?.camera else { return nil }
            let m = camera.transform
            let pos = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
            let forward = -SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
            let up = SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z)
            return pos + forward * 0.3 - up * 0.12
        }

        private func launch(toward id: Int, quality: Double, in view: ARView) {
            guard let p = placed[id], let from = handPosition(view) else { return }
            let to = p.holder.position(relativeTo: nil) + [0, 0.2, 0]
            let distance = simd_distance(from, to)
            let ball = makeBall()
            ball.position = from
            root.addChild(ball)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            flights.append(Flight(ball: ball, start: CACurrentMediaTime(), duration: 0.35 + 0.08 * Double(distance),
                                  from: from, to: to, apex: 0.25 + 0.05 * distance, targetID: id, quality: quality))
        }

        private func launchMiss(direction: CGVector, in view: ARView, short: Bool = false) {
            guard let from = handPosition(view), let camera = view.session.currentFrame?.camera else { return }
            let m = camera.transform
            let forward = -SIMD3(m.columns.2.x, 0, m.columns.2.z)
            let right = SIMD3(m.columns.0.x, 0, m.columns.0.z)
            let flat = simd_length(forward) > 0.001 ? simd_normalize(forward) : SIMD3<Float>(0, 0, -1)
            let sideways = Float(direction.dx) * 1.5
            var to = from + flat * (short ? 1.0 : 3.0) + right * sideways
            to.y = from.y - (short ? 1.0 : 1.3)
            let ball = makeBall()
            ball.position = from
            root.addChild(ball)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            flights.append(Flight(ball: ball, start: CACurrentMediaTime(), duration: short ? 0.5 : 0.8,
                                  from: from, to: to, apex: 0.3, targetID: nil, quality: 0))
        }

        private func updateFlights(now: CFTimeInterval) {
            var landed: [Flight] = []
            for f in flights {
                let t = Float(min(1, (now - f.start) / f.duration))
                var p = f.from + (f.to - f.from) * t
                p.y += 4 * f.apex * t * (1 - t)   // parabola peaking at the midpoint
                f.ball.position = p
                f.ball.orientation = simd_quatf(angle: t * 8, axis: [1, 0, 0])
                if t >= 1 { landed.append(f) }
            }
            guard !landed.isEmpty else { return }
            flights.removeAll { f in landed.contains { $0.ball === f.ball } }
            for f in landed {
                if let id = f.targetID, placed[id] != nil, !(placed[id]?.busy ?? true) {
                    capture(id: id, ball: f.ball, quality: f.quality)
                } else {
                    if f.targetID != nil { model.missed() }
                    fadeOut(f.ball, after: 0.6)
                }
            }
        }

        // MARK: Capture sequence

        private func capture(id: Int, ball: Entity, quality: Double) {
            guard var p = placed[id] else { return }
            guard let outcome = model.resolveThrow(spawnID: id, quality: quality) else {
                model.missed()
                fadeOut(ball, after: 0.4)
                return
            }
            p.busy = true
            placed[id] = p
            let holder = p.holder
            let spawn = p.spawn
            let home = holder.transform

            Task { @MainActor in
                // Creature is drawn into the ball.
                var sucked = home
                sucked.scale = SIMD3(repeating: 0.01)
                sucked.translation = ball.position(relativeTo: root)
                holder.move(to: sucked, relativeTo: root, duration: 0.25, timingFunction: .easeIn)
                try? await Task.sleep(for: .milliseconds(300))

                // Ball drops to the creature's feet and wobbles.
                var ground = ball.transform
                ground.translation = home.translation + [0, Self.ballRadius, 0]
                ball.move(to: ground, relativeTo: root, duration: 0.25, timingFunction: .easeIn)
                try? await Task.sleep(for: .milliseconds(450))

                let wobbles: Int = switch outcome {
                case .caught: 3
                case .brokeFree: Int.random(in: 1...2)
                case .fled: 1
                }
                for i in 0..<wobbles {
                    var tilt = ground
                    tilt.rotation = simd_quatf(angle: i % 2 == 0 ? 0.45 : -0.45, axis: [0, 0, 1])
                    ball.move(to: tilt, relativeTo: root, duration: 0.15)
                    try? await Task.sleep(for: .milliseconds(180))
                    ball.move(to: ground, relativeTo: root, duration: 0.15)
                    try? await Task.sleep(for: .milliseconds(450))
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                }

                switch outcome {
                case .caught:
                    var pop = ground
                    pop.scale = SIMD3(repeating: 1.4)
                    ball.move(to: pop, relativeTo: root, duration: 0.12)
                    try? await Task.sleep(for: .milliseconds(150))
                    self.fadeOut(ball, after: 0)
                    holder.removeFromParent()
                    self.placed[id] = nil
                case .brokeFree:
                    holder.move(to: home, relativeTo: root, duration: 0.25, timingFunction: .easeOut)
                    self.fadeOut(ball, after: 0)
                    try? await Task.sleep(for: .milliseconds(300))
                    self.placed[id]?.busy = false
                case .fled:
                    self.fadeOut(ball, after: 0)
                    var away = home
                    away.translation.y += 0.6
                    away.scale = SIMD3(repeating: 0.01)
                    holder.move(to: away, relativeTo: root, duration: 0.5, timingFunction: .easeIn)
                    try? await Task.sleep(for: .milliseconds(550))
                    holder.removeFromParent()
                    self.placed[id] = nil
                }
                self.model.announce(outcome, spawn: spawn, quality: quality)
            }
        }

        private func fadeOut(_ entity: Entity, after delay: Double) {
            Task { @MainActor in
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                var gone = entity.transform
                gone.scale = SIMD3(repeating: 0.01)
                entity.move(to: gone, relativeTo: entity.parent, duration: 0.15)
                try? await Task.sleep(for: .milliseconds(170))
                entity.removeFromParent()
            }
        }
    }
}
