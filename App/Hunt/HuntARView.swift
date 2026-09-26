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
        /// What a creature is doing, like the overworld behaviour in the games.
        private enum Activity {
            case idle(until: Double)
            case walking(to: SIMD3<Float>, running: Bool)
            case doing(clip: String, until: Double)   // eat / rest / sleep / glad / roar
            case noticing(until: Double)
        }

        private struct Placed {
            let holder: Entity
            let spawn: Spawn
            /// Where it spawned; it wanders around this spot.
            let home: SIMD3<Float>
            var position: SIMD3<Float>
            var yaw: Float
            var creature: CreatureModel?
            var activity: Activity = .idle(until: 0)
            var lastNoticed: Double = -100
            var busy = false

            /// Eating, resting or asleep: easier to catch.
            var isUnaware: Bool {
                if case .doing(let clip, _) = activity { return ["eat", "rest", "sleep"].contains(clip) }
                return false
            }
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
            let dt = Float(min(0.1, lastFrame == 0 ? 0 : now - lastFrame))
            lastFrame = now
            for id in Array(placed.keys) {
                guard var p = placed[id], !p.busy else { continue }
                behave(&p, now: now, dt: dt, camera: cam)
                var shown = p.position
                if p.spawn.height > 0 { shown.y += 0.05 * sin(Float(now) * 1.3 + Float(id)) }   // flyers bob
                p.holder.position = shown
                p.holder.orientation = simd_quatf(angle: p.yaw, axis: [0, 1, 0])
                placed[id] = p
            }

            if now - lastIndicatorUpdate > 0.2 {
                lastIndicatorUpdate = now
                updateIndicators(in: view, camera: camera)
            }
        }

        private var lastFrame: CFTimeInterval = 0

        // MARK: Behaviour

        /// How far a creature strays from where it spawned.
        private static func roam(for rarity: Rarity) -> Float {
            switch rarity {
            case .common: 0.8
            case .uncommon: 1.0
            case .rare: 1.3
            case .epic: 1.6
            case .legendary: 2.0
            }
        }

        /// Chance it runs off when you get close.
        private static func skittishness(for rarity: Rarity) -> Double {
            switch rarity {
            case .common: 0.05
            case .uncommon: 0.15
            case .rare: 0.35
            case .epic: 0.5
            case .legendary: 0.65
            }
        }

        private func behave(_ p: inout Placed, now: Double, dt: Float, camera: SIMD3<Float>) {
            guard let creature = p.creature else { return }
            let scale = max(0.5, creature.height / 0.5)
            var toCamera = camera - p.position
            toCamera.y = 0
            let distance = simd_length(toCamera)

            // Noticing the player, like wild creatures in the games.
            if distance < 1.5, now - p.lastNoticed > 10 {
                p.lastNoticed = now
                if Double.random(in: 0..<1) < Self.skittishness(for: p.spawn.rarity) {
                    let away = distance > 0.01 ? -toCamera / distance : SIMD3<Float>(0, 0, 1)
                    var target = p.position + away * Self.roam(for: p.spawn.rarity) * 1.2
                    target = clampToRoam(target, p)
                    p.activity = .walking(to: target, running: true)
                } else {
                    p.activity = .noticing(until: now + max(1.2, creature.play("notice")))
                }
            }

            switch p.activity {
            case .idle(let until):
                creature.play("idle", loop: true)
                if now >= until { p.activity = nextActivity(for: p, creature: creature, now: now) }
            case .walking(let target, let running):
                creature.play(running ? "run" : "walk", loop: true)
                var step = target - p.position
                step.y = 0
                let remaining = simd_length(step)
                let speed = (running ? 0.9 : 0.28) * scale
                if remaining < 0.04 {
                    p.activity = .idle(until: now + Double.random(in: 1.5...4))
                } else {
                    let move = min(remaining, speed * dt)
                    p.position += step / remaining * move
                    turn(&p, toward: atan2(step.x, step.z), dt: dt)
                }
            case .doing(let clip, let until):
                // Loops are re-asserted (a no-op while playing); one-shots were started once.
                if ["eat", "rest", "sleep"].contains(clip) { creature.play(clip, loop: true) }
                if now >= until { p.activity = .idle(until: now + 1) }
            case .noticing(let until):
                turn(&p, toward: atan2(toCamera.x, toCamera.z), dt: dt)
                if now >= until { p.activity = .idle(until: now + Double.random(in: 1...2.5)) }
            }
        }

        private func nextActivity(for p: Placed, creature: CreatureModel, now: Double) -> Activity {
            let roll = Double.random(in: 0..<1)
            switch roll {
            case ..<0.55:
                let angle = Float.random(in: 0..<(2 * .pi))
                let radius = Float.random(in: 0.3...1) * Self.roam(for: p.spawn.rarity)
                let target = p.home + SIMD3(sin(angle) * radius, 0, cos(angle) * radius)
                return .walking(to: SIMD3(target.x, p.position.y, target.z), running: false)
            case ..<0.67 where creature.has("eat"):
                return .doing(clip: "eat", until: now + Double.random(in: 3...6))
            case ..<0.75 where creature.has("rest"):
                return .doing(clip: "rest", until: now + Double.random(in: 4...8))
            case ..<0.80 where creature.has("sleep"):
                return .doing(clip: "sleep", until: now + Double.random(in: 6...10))
            case ..<0.88:
                let clip = Bool.random() ? "glad" : "roar"
                return .doing(clip: clip, until: now + max(1, creature.play(clip)))
            default:
                return .idle(until: now + Double.random(in: 2...4))
            }
        }

        private func clampToRoam(_ target: SIMD3<Float>, _ p: Placed) -> SIMD3<Float> {
            var offset = target - p.home
            offset.y = 0
            let limit = Self.roam(for: p.spawn.rarity) * 1.5
            let length = simd_length(offset)
            if length > limit { offset *= limit / length }
            return SIMD3(p.home.x + offset.x, p.position.y, p.home.z + offset.z)
        }

        private func turn(_ p: inout Placed, toward target: Float, dt: Float) {
            var delta = target - p.yaw
            while delta > .pi { delta -= 2 * .pi }
            while delta < -.pi { delta += 2 * .pi }
            let maxTurn = 4 * dt
            p.yaw += max(-maxTurn, min(maxTurn, delta))
        }

        private func place(_ spawn: Spawn, origin: simd_float4x4, in view: ARView) {
            let holder = Entity()
            holder.name = "spawn-\(spawn.id)"
            let base = position(for: spawn, origin: origin, in: view)
            holder.position = base
            root.addChild(holder)
            // Start facing the player, then go about its business.
            let cam = view.session.currentFrame.map { SIMD3($0.camera.transform.columns.3.x, 0, $0.camera.transform.columns.3.z) } ?? base
            placed[spawn.id] = Placed(holder: holder, spawn: spawn, home: base, position: base,
                                      yaw: atan2(cam.x - base.x, cam.z - base.z))

            let species = model.species(for: spawn)
            Task { [weak self] in
                guard let self else { return }
                let creature = await CreatureModel.load(for: species, name: species?.name ?? "?",
                                                        shiny: spawn.isShiny, rarity: spawn.rarity, packs: self.packs)
                guard self.placed[spawn.id]?.holder === holder else { return }
                // Pop in. Animate the child: the holder's position is driven every frame.
                let content = creature.root
                content.scale = SIMD3(repeating: 0.01)
                holder.addChild(content)
                holder.generateCollisionShapes(recursive: true)
                content.move(to: Transform(scale: .one, rotation: content.orientation, translation: content.position),
                             relativeTo: holder, duration: 0.3, timingFunction: .easeOut)
                self.placed[spawn.id]?.creature = creature
                self.placed[spawn.id]?.activity = .idle(until: CACurrentMediaTime() + Double.random(in: 0.5...2))
                if spawn.rarity >= .epic { creature.play("roar") }
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
            // Sneaking up on one that's eating, resting or asleep pays off.
            let quality = min(1, quality + (p.isUnaware ? 0.15 : 0))
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
                    // It's awake and annoyed now.
                    if let creature = self.placed[id]?.creature {
                        self.placed[id]?.activity = .noticing(until: CACurrentMediaTime() + max(1, creature.play("roar")))
                        self.placed[id]?.lastNoticed = CACurrentMediaTime()
                    }
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
