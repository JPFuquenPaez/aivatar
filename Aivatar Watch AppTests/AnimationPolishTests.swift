import XCTest
import CoreGraphics
@testable import Aivatar_Watch_App

/// v1.3 §5.14B acceptance tests — the animation polish pack: overlap budgets
/// (ears trail the head by > 1.2x), two-phase anticipation is already pinned
/// in PuppetPoserTests, moving holds make the 60 s idle non-periodic, and
/// the surprise scheduler fires rare, irregular, min-gapped micro-events
/// deterministically per seed.
final class AnimationPolishTests: XCTestCase {

    /// (a) Motion lint: on a step input, the ear channel's settle time must
    /// exceed 1.2x the head channel's — secondary parts visibly trail the
    /// primary mass (overlap communicates weight).
    func testEarSettleExceedsHeadSettleBy1_2x() throws {
        var target = PuppetPose()
        target.headTilt = 0.3
        target.earL = 1.0
        var bank = PuppetSpringBank(pose: PuppetPose())
        let dt = 1.0 / 60.0
        var headSettledAt: Double?
        var earSettledAt: Double?
        var headErr = 0.0
        var earErr = 0.0
        for step in 0..<1200 {  // 20 s at 60 fps
            let live = bank.interpolate(target: target, dt: dt)
            let t = Double(step) * dt
            headErr = abs(Double(live.headTilt) - 0.3)
            earErr = abs(Double(live.earL) - 1.0)
            if headErr < 0.02, headSettledAt == nil { headSettledAt = t }
            if earErr < 0.02, earSettledAt == nil { earSettledAt = t }
            // Once settled, require it to STAY settled (no late wobble).
            if let h = headSettledAt, t > h + 0.5 { XCTAssertLessThan(headErr, 0.02) }
            if let e = earSettledAt, t > e + 0.5 { XCTAssertLessThan(earErr, 0.02) }
        }
        let head = try XCTUnwrap(headSettledAt, "head never settles")
        let ear = try XCTUnwrap(earSettledAt, "ear never settles")
        XCTAssertGreaterThanOrEqual(ear, head * 1.2,
            "ear settle \(ear)s must be >= 1.2x head settle \(head)s")
        XCTAssertLessThanOrEqual(ear, head * 2.5, "ears must not lag absurdly")
    }

    /// (c) A 60-second idle capture must FAIL a periodicity test: the moving
    /// holds (per-part micro-noise) make the ambient signal non-periodic at
    /// the breath period.
    func testIdleAmbientIsNotPeriodicAtTheBreathPeriod() {
        let period = 2.2
        let dt = 1.0 / 30.0
        var samples: [Double] = []
        var t = 0.0
        while t < 60.0 {
            var pose = PuppetPose()
            PuppetAmbient.apply(to: &pose, at: t, full: true, moodAmp: 1.0)
            samples.append(Double(pose.earL) + Double(pose.tailAngle))
            t += dt
        }
        XCTAssertGreaterThan(samples.count, 1700)
        // RMS mismatch at the breath lag: a purely periodic signal would be ~0.
        let lag = Int(period / dt)
        var rms = 0.0
        var n = 0
        for i in 0..<(samples.count - lag) {
            let d = samples[i] - samples[i + lag]
            rms += d * d
            n += 1
        }
        rms = sqrt(rms / Double(n))
        XCTAssertGreaterThan(rms, 1e-4,
            "the 60 s idle is periodic at the breath period (rms \(rms)) — the moving holds are missing")
        // And the micro-noise is actually alive (nonzero variance).
        let mean = samples.reduce(0, +) / Double(samples.count)
        let variance = samples.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(samples.count)
        XCTAssertGreaterThan(variance, 1e-5, "ear/tail micro-noise carries no energy")
    }

    /// (d) The surprise scheduler: deterministic per seed, rare, min-gapped
    /// per kind, and irregular (not a fixed metronome).
    func testSurpriseSchedulerIsDeterministicRareAndIrregular() throws {
        func run(_ seed: UInt64) throws -> [(kind: Int, tick: Int)] {
            let profile = try PersonalityProfile.load(.ember)
            let d = SpriteDirector(profile: profile, seed: seed)
            d.advance(toTick: 4000)  // 10 director-minutes
            return d.surpriseFires
        }
        let a = try run(20261010).map { "\($0.kind):\($0.tick)" }
        let b = try run(20261010).map { "\($0.kind):\($0.tick)" }
        XCTAssertEqual(a, b, "same seed -> same surprises (determinism)")
        let raw = try run(20261010)
        XCTAssertFalse(raw.isEmpty, "a 10-minute idle must contain at least one surprise")
        XCTAssertLessThanOrEqual(raw.count, 20, "surprises stay rare (<= 1 per 30 s)")
        // Per-kind min gap holds.
        var lastOfKind: [Int: Int] = [:]
        for fire in raw {
            if let last = lastOfKind[fire.kind] {
                XCTAssertGreaterThanOrEqual(fire.tick - last, SpriteDirector.surpriseMinGapTicks,
                    "surprise kind \(fire.kind) fired inside its min gap")
            }
            lastOfKind[fire.kind] = fire.tick
        }
        // Irregular: not all inter-fire gaps identical.
        let gaps = zip(raw.dropFirst().map { $0.tick }, raw.map { $0.tick }).map { $0 - $1 }
        if gaps.count > 2 {
            XCTAssertGreaterThan(Set(gaps).count, 1, "surprises fire on a fixed metronome")
        }
        // A different seed fires a different schedule.
        let c = try run(999).map { "\($0.kind):\($0.tick)" }
        XCTAssertNotEqual(a, c, "the seed matters")
    }
}
