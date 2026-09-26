import Foundation

/// SplitMix64: tiny, fast, and identical on every device.
///
/// Two players' phones must agree on things like which species a round
/// offers or how a catch roll lands when replayed, so gameplay randomness
/// never uses the system generator. The helpers below are implemented here
/// rather than via `Int.random(in:using:)`, whose algorithm the standard
/// library is free to change between Swift versions.
public struct SeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    /// A generator for one labelled purpose ("spawns", "catch:3", …) derived
    /// from a round seed, so adding a new use never shifts existing streams.
    public init(seed: UInt64, label: String) {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in label.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        self.init(seed: seed ^ hash)
        _ = next()
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in `0..<bound` (rejection sampling, no modulo bias).
    public mutating func int(below bound: Int) -> Int {
        precondition(bound > 0, "bound must be positive")
        let n = UInt64(bound)
        let limit = UInt64.max - UInt64.max % n
        while true {
            let x = next()
            if x < limit { return Int(x % n) }
        }
    }

    /// Uniform in `range` (inclusive).
    public mutating func int(in range: ClosedRange<Int>) -> Int {
        range.lowerBound + int(below: range.upperBound - range.lowerBound + 1)
    }

    /// Uniform in [0, 1).
    public mutating func unit() -> Double {
        Double(next() >> 11) * 0x1.0p-53
    }

    public mutating func chance(_ probability: Double) -> Bool {
        unit() < probability
    }

    public mutating func pick<T>(_ items: [T]) -> T? {
        items.isEmpty ? nil : items[int(below: items.count)]
    }

    /// Picks an index with probability proportional to `weights`.
    public mutating func weightedIndex(_ weights: [Double]) -> Int? {
        let total = weights.reduce(0) { $0 + max(0, $1) }
        guard total > 0 else { return nil }
        var roll = unit() * total
        for (i, w) in weights.enumerated() where w > 0 {
            if roll < w { return i }
            roll -= w
        }
        return weights.lastIndex { $0 > 0 }
    }

    public mutating func shuffled<T>(_ items: [T]) -> [T] {
        var out = items
        guard out.count > 1 else { return out }
        for i in stride(from: out.count - 1, to: 0, by: -1) {
            out.swapAt(i, int(below: i + 1))
        }
        return out
    }
}
