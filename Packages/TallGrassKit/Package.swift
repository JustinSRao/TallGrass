// swift-tools-version: 6.0
import PackageDescription

// TallGrassKit holds TallGrass's platform-independent rules: seeded
// randomness, rarity, spawning, catching, hunt rounds, move loadouts and
// the creature-pack format. No ARKit/SwiftUI/JavaScriptCore dependency, so
// `swift test` checks it quickly on any Mac (including GitHub's).
let package = Package(
    name: "TallGrassKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "TallGrassKit", targets: ["TallGrassKit"])
    ],
    targets: [
        .target(name: "TallGrassKit"),
        .testTarget(name: "TallGrassKitTests", dependencies: ["TallGrassKit"])
    ],
    swiftLanguageModes: [.v5]
)
