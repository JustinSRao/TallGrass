import Combine
import SwiftUI
import TallGrassKit

struct HuntView: View {
    @Bindable var model: HuntModel
    let onFinish: ([BattleMon]) -> Void
    @Environment(PackStore.self) private var packs

    private let clock = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            HuntARView(model: model, packs: packs)
                .ignoresSafeArea()

            VStack {
                HStack {
                    Label(timeText, systemImage: "timer")
                    Spacer()
                    Label("\(model.team.count)/\(model.session.config.teamSize)", systemImage: "circle.grid.3x3")
                    Spacer()
                    Label("\(model.visible.count) nearby", systemImage: "dot.radiowaves.left.and.right")
                }
                .font(.headline.monospacedDigit())
                .padding()
                .background(.ultraThinMaterial, in: .rect(cornerRadius: 14))
                .padding(.horizontal)

                Spacer()

                if let message = model.message {
                    Text(message)
                        .font(.headline)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: .capsule)
                        .transition(.opacity)
                }
                Text("Tap a creature to throw. Centre it for a better throw.")
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .shadow(radius: 3)
                Button("End Hunt") { onFinish(model.team) }
                    .buttonStyle(.borderedProminent)
                    .padding(.bottom)
            }
        }
        .onAppear { model.start() }
        .onReceive(clock) { _ in model.tick() }
        .sheet(isPresented: .constant(model.isOver)) {
            HuntResultsView(team: model.team) { onFinish(model.team) }
                .interactiveDismissDisabled()
        }
    }

    private var timeText: String {
        let s = Int(model.timeRemaining.rounded(.up))
        return String(format: "%d:%02d", s / 60, s % 60)
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
                ForEach(team, id: \.self) { TeamRow(mon: $0) }
            }
            .navigationTitle("Time's Up!")
            .toolbar {
                Button("Done", action: onDone)
            }
        }
    }
}
