import Combine
import SwiftUI
import TallGrassKit

struct HuntView: View {
    @Bindable var model: HuntModel
    /// Solo hunts show a results sheet; in a match the match screen takes over.
    var showsResults = true
    var opponentStatus: String?
    let onFinish: ([BattleMon]) -> Void
    @Environment(PackStore.self) private var packs
    @State private var finished = false

    private let clock = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            HuntARView(model: model, packs: packs)
                .ignoresSafeArea()

            EdgeArrows(indicators: model.indicators)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack {
                HStack {
                    Label(timeText, systemImage: "timer")
                        .foregroundStyle(model.timeRemaining < 20 ? .red : .primary)
                    Spacer()
                    Label("\(model.team.count)/\(model.session.config.teamSize)", systemImage: "circle.grid.3x3.fill")
                    Spacer()
                    Label("\(model.visible.count)", systemImage: "eye")
                }
                .font(.headline.monospacedDigit())
                .padding()
                .background(.ultraThinMaterial, in: .rect(cornerRadius: 14))
                .padding(.horizontal)

                if let opponentStatus {
                    Text(opponentStatus)
                        .font(.caption)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: .capsule)
                }

                Spacer()

                if let message = model.message {
                    Text(message)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: .capsule)
                        .transition(.scale.combined(with: .opacity))
                }
                TeamStrip(team: model.team)
                Text("Swipe up to throw · follow the arrows to find more")
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .shadow(radius: 3)
                Button("End Hunt") { finish() }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .padding(.bottom)
            }
            .animation(.spring(duration: 0.3), value: model.message)

            if model.countdown > 0 {
                Text("\(Int(model.countdown.rounded(.up)))")
                    .font(.system(size: 120, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(radius: 10)
                    .contentTransition(.numericText())
            }
        }
        .onReceive(clock) { _ in
            model.tick()
            if model.isOver, !finished, !showsResults { finish() }
        }
        .sheet(isPresented: .constant(showsResults && model.isOver)) {
            HuntResultsView(team: model.team) { finish() }
                .interactiveDismissDisabled()
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onFinish(model.team)
    }

    private var timeText: String {
        let s = Int(model.timeRemaining.rounded(.up))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Arrows at the screen edge pointing toward creatures you can't see.
private struct EdgeArrows: View {
    let indicators: [HuntModel.Indicator]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ForEach(indicators) { ind in
                let dx = cos(ind.angle), dy = sin(ind.angle)
                // Push the point out along the direction until it hits the inset edge.
                let rx = (w / 2 - 36) / max(abs(dx), 0.001)
                let ry = (h / 2 - 90) / max(abs(dy), 0.001)
                let r = min(rx, ry)
                Image(systemName: "arrowtriangle.right.fill")
                    .font(.system(size: ind.rarity >= .epic ? 30 : 22))
                    .foregroundStyle(Color(CreatureEntity.color(for: ind.rarity, shiny: false)))
                    .shadow(color: .black.opacity(0.5), radius: 3)
                    .rotationEffect(.radians(ind.angle))
                    .position(x: w / 2 + dx * r, y: h / 2 + dy * r)
            }
        }
    }
}

private struct TeamStrip: View {
    let team: [BattleMon]

    var body: some View {
        if !team.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(team.enumerated()), id: \.offset) { _, mon in
                        Text((mon.shiny ? "✨" : "") + mon.species)
                            .font(.caption.bold())
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: .capsule)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

struct HuntResultsView: View {
    let team: [BattleMon]
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if team.isEmpty {
                    Text("Nothing caught this time.")
                }
                ForEach(Array(team.enumerated()), id: \.offset) { _, mon in TeamRow(mon: mon) }
            }
            .navigationTitle("Time's Up!")
            .toolbar {
                Button("Done", action: onDone)
            }
        }
    }
}
