import Foundation
import Observation
import SwiftUI

/// Plays a battle's beats one at a time: types the line out, runs the arena
/// animation alongside it, and only then updates what the HP bars show, so
/// the screen reads like the games instead of dumping a log.
@MainActor @Observable
final class BattlePlayer {
    private(set) var text = ""
    private(set) var visibleCount = 0
    private(set) var display: [String: BattleController.Combatant] = [:]
    private(set) var isPlaying = false
    var arenaPlaced = false

    /// Set by the AR arena; awaited so text and animation finish together.
    @ObservationIgnored var perform: (@MainActor (BattleController.StageEvent) async -> Void)?
    @ObservationIgnored private var cursor = 0
    @ObservationIgnored private var skipRequested = false

    var visibleText: String { String(text.prefix(visibleCount)) }
    var isTyping: Bool { visibleCount < text.count }

    /// Call whenever the controller may have new beats.
    func sync(_ battle: BattleController) {
        guard !isPlaying, cursor < battle.beats.count else { return }
        isPlaying = true
        Task { await run(battle) }
    }

    /// Tap on the message box: finish typing, then move on.
    func skip() {
        skipRequested = true
    }

    private func run(_ battle: BattleController) async {
        while cursor < battle.beats.count {
            let beat = battle.beats[cursor]
            cursor += 1
            skipRequested = false
            if let side = beat.side, let combatant = beat.combatant {
                withAnimation(.easeOut(duration: 0.6)) { display[side] = combatant }
            }
            async let animation: Void = act(beat.event)
            if let line = beat.text {
                await type(line)
                await hold(0.6 + Double(line.count) * 0.012)
            }
            await animation
        }
        isPlaying = false
        if cursor < battle.beats.count { sync(battle) }   // beats that arrived at the very end
    }

    private func act(_ event: BattleController.StageEvent?) async {
        guard let event, let perform else { return }
        await perform(event)
    }

    private func type(_ line: String) async {
        text = line
        visibleCount = 0
        for i in 1...max(1, line.count) {
            if skipRequested {
                skipRequested = false
                break
            }
            visibleCount = i
            try? await Task.sleep(for: .milliseconds(16))
        }
        visibleCount = line.count
    }

    private func hold(_ seconds: Double) async {
        var waited = 0.0
        while waited < seconds, !skipRequested {
            try? await Task.sleep(for: .milliseconds(50))
            waited += 0.05
        }
        skipRequested = false
    }
}
