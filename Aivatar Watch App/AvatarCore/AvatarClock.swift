import Foundation

/// Deterministic frame-locked clock (§7 "Deterministic clock & seeded randomness").
///
/// Engine time is *always* derived from an integer frame index, never from wall
/// clock, so `same seed + same frame -> same pose` holds for replay and CI
/// golden-frame tests. The renderer maps wall-clock time to a frame index and
/// the engine steps through every skipped frame so stochastic scheduling
/// statistics stay correct.
nonisolated struct AvatarClock: Sendable, Equatable {
    let frameRate: Int
    private(set) var frame: Int
    let seed: UInt64

    init(seed: UInt64, frameRate: Int = 30, startFrame: Int = 0) {
        precondition(frameRate > 0)
        self.seed = seed
        self.frameRate = frameRate
        self.frame = startFrame
    }

    var time: Double {
        Double(frame) / Double(frameRate)
    }

    /// Frame duration in seconds (`1/30` at the plan-mandated 30 FPS).
    var frameDuration: Double {
        1.0 / Double(frameRate)
    }

    /// Advances exactly one frame. Returns false if already at or past `target`.
    @discardableResult
    mutating func advance(to target: Int) -> Bool {
        guard frame < target else { return false }
        frame += 1
        return true
    }

    /// Frame index for a wall-clock instant, quantized to the tick grid.
    func frameIndex(at elapsed: TimeInterval) -> Int {
        Int((elapsed / frameDuration).rounded(.down))
    }
}

/// SplitMix64: tiny, fast, high-quality 64-bit PRNG. Fully deterministic.
nonisolated struct SeededRandom: Sendable {
    var state: UInt64

    init(_ seed: UInt64) {
        state = seed
    }

    mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// Uniform float in [0, 1).
    mutating func nextFloat() -> Float {
        Float(nextUInt64() >> 40) * (1.0 / Float(1 << 24))
    }

    /// Uniform float in [-1, 1).
    mutating func nextSignedFloat() -> Float {
        nextFloat() * 2 - 1
    }

    /// Uniform integer in 0..<upperBound (unbiased).
    mutating func nextInt(_ upperBound: Int) -> Int {
        precondition(upperBound > 0)
        let bound = UInt64(upperBound)
        let limit = UInt64.max - UInt64.max % bound
        var r = nextUInt64()
        while r >= limit { r = nextUInt64() }
        return Int(r % bound)
    }
}
