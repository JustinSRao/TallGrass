import SwiftUI

@main
struct TallGrassApp: App {
    @State private var packs = PackStore()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(packs)
        }
    }
}
