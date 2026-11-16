import XCTest
import CoreGraphics
@testable import Aivatar_Watch_App

/// v3 PuppetSpringTests: the display-rate motion layer. The single-spring
/// integrator (semi-implicit, dt clamped at 1/30) obeys the overshoot
/// budgets per damping zone (the juice is 5-10% — never more), the bank
/// interpolates a whole pose deterministically and settles exactly on the
/// target (the truth layer), and the ambient envelopes (breath, sway,
/// micro) stay bounded, periodic, and Reduce-Motion aware.
final class PuppetSpringTests: XCTestCase {

    // MARK: - The integrator

    func testDtClampedSanely() {
        // Negative and NaN dt produce no motion at all.
        var a = PuppetSpring(value: 0)
        XCTAssertEqual(a.step(target: 1, response: 0.3, damping: 0.6, dt: -1), 0)
        XCTAssertEqual(a.step(target: 1, response: 0.3, damping: 0.6, dt: .nan), 0)
        // A huge dt behaves exactly like one clamped 1/30 step.
        var b = PuppetSpring(value: 0)
        var c = PuppetSpring(value: 0)
        _ = b.step(target: 1, response: 0.3, damping: 0.6, dt: 5)
        _ = c.step(target: 1, response: 0.3, damping: 0.6, dt: 1.0 / 30.0)
        XCTAssertEqual(b.value, c.value, accuracy: 0.001)
    }

    func testSpringConvergesWithinASecond() {
        var spring = PuppetSpring(value: 0)
        var peak: CGFloat = 0
        var t: Double = 0
        while t < 1.2 {
            peak = max(peak, spring.step(target: 1, response: 0.30, damping: 0.60, dt: 1.0 / 60.0))
            t += 1.0 / 60.0
        }
        XCTAssertGreaterThanOrEqual(spring.value, 0.98, "settles on target")
        XCTAssertLessThanOrEqual(peak, 1.25, "overshoot stays in the juice budget")
    }

    /// The per-channel damping zones, pinned: the hop channel (0.25, 0.55)
    /// overshoots visibly (5-20%), the face channels (lids 0.14/0.85, pupils
    /// 0.12/0.88) never overshoot meaningfully — eyes do not bounce.
    func testOvershootBudgetsPerChannelZone() {
        func overshoot(response: Double, damping: Double) -> Double {
            var spring = PuppetSpring(value: 0)
            var peak: CGFloat = 0
            for _ in 0..<480 {
                peak = max(peak, spring.step(target: 1, response: response, damping: damping,
                                              dt: 1.0 / 60.0))
            }
            return Double(peak) - 1.0
        }
        let hop = overshoot(response: 0.25, damping: 0.55)
        XCTAssertGreaterThanOrEqual(hop, 0.02, "the hop springs (visible overshoot)")
        XCTAssertLessThanOrEqual(hop, 0.18)
        let lids = overshoot(response: 0.14, damping: 0.85)
        XCTAssertLessThanOrEqual(lids, 0.015, "lids settle without bouncing")
        let pupils = overshoot(response: 0.12, damping: 0.88)
        XCTAssertLessThanOrEqual(pupils, 0.01, "saccades never overshoot")
    }

    func testStepSizeIndependence() {
        // Frame drops must not change where the motion lands.
        var fine: CGFloat = 0
        var coarse: CGFloat = 0
        var springA = PuppetSpring(value: 0)
        var springB = PuppetSpring(value: 0)
        for _ in 0..<240 { fine = springA.step(target: 1, response: 0.3, damping: 0.6, dt: 1.0 / 120.0) }
        for _ in 0..<120 { coarse = springB.step(target: 1, response: 0.3, damping: 0.6, dt: 1.0 / 60.0) }
        XCTAssertEqual(fine, coarse, accuracy: 0.02, "same wall time -> same landing")
    }

    // MARK: - The bank

    func testBankSettlesOnTheTargetPose() {
        let idle = PuppetPose()
        let happy = PuppetPoser.resolve(PuppetDrive(archetype: .ember, frameID: "happy")).pose
        var bank = PuppetSpringBank(pose: idle)
        var live = idle
        for _ in 0..<480 {
            live = bank.interpolate(target: happy, dt: 1.0 / 60.0)  // 8 s of life
        }
        XCTAssertEqual(live.lidOpen, happy.lidOpen, accuracy: 0.002)
        XCTAssertEqual(live.earL, happy.earL, accuracy: 0.002)
        XCTAssertEqual(live.bodyScaleY, happy.bodyScaleY, accuracy: 0.002)
        XCTAssertEqual(live.mouth, happy.mouth)
        XCTAssertEqual(live.fingerprint(), happy.fingerprint(),
                       "the bank lands on the truth layer's pose")
        // Mid-flight the lid never bounces past its own target band.
        var launchBank = PuppetSpringBank(pose: idle)
        var minLid: CGFloat = 1
        var maxLid: CGFloat = 0
        for _ in 0..<120 {
            let mid = launchBank.interpolate(target: happy, dt: 1.0 / 60.0)
            minLid = min(minLid, mid.lidOpen)
            maxLid = max(maxLid, mid.lidOpen)
        }
        XCTAssertGreaterThanOrEqual(minLid, 0.17, "lids descend monotonically to 0.18")
        XCTAssertLessThanOrEqual(maxLid, 1.001)
    }

    func testBankIsDeterministicAndResetsExactly() {
        let target = PuppetPoser.resolve(PuppetDrive(archetype: .willow, frameID: "quirk")).pose
        func run() -> [PuppetPose] {
            var bank = PuppetSpringBank()
            var out: [PuppetPose] = []
            for _ in 0..<100 {
                out.append(bank.interpolate(target: target, dt: 1.0 / 60.0))
            }
            return out
        }
        XCTAssertEqual(run(), run(), "two identical banks trace bit-identically")
        var bank = PuppetSpringBank()
        _ = bank.interpolate(target: target, dt: 1.0 / 60.0)
        bank.reset(to: target)
        XCTAssertEqual(bank.interpolate(target: target, dt: 1.0 / 60.0), target,
                       "reset pins every channel at the pose")
    }

    // MARK: - Ambient envelopes (pure time functions)

    func testBreathIsBoundedAndPeriodic() {
        for t in stride(from: 0.0, through: 1.1, by: 0.1) {
            let a = PuppetAmbient.breathe(at: t)
            let b = PuppetAmbient.breathe(at: t + 2.2)
            XCTAssertEqual(a.bodyScaleY, b.bodyScaleY, accuracy: 1e-9, "2.2 s period")
            XCTAssertEqual(a.headBobY, b.headBobY, accuracy: 1e-9)
        }
        var minY = 2.0, maxY = 0.0, minBob = 10.0, maxBob = -10.0
        for t in stride(from: 0.0, through: 4.4, by: 1.0 / 60.0) {
            let breath = PuppetAmbient.breathe(at: t)
            minY = min(minY, breath.bodyScaleY)
            maxY = max(maxY, breath.bodyScaleY)
            minBob = min(minBob, breath.headBobY)
            maxBob = max(maxBob, breath.headBobY)
        }
        XCTAssertEqual(minY, 0.96, accuracy: 0.001, "the exhale squashes 4%")
        XCTAssertEqual(maxY, 1.04, accuracy: 0.001)
        XCTAssertEqual(minBob, -3.6, accuracy: 0.01)
        XCTAssertEqual(maxBob, 3.6, accuracy: 0.01)
    }

    func testTailSwayFlutterPupilMicroBounds() {
        var sway = 0.0
        for t in stride(from: 0.0, through: 5.0, by: 1.0 / 30.0) {
            sway = max(sway, abs(PuppetAmbient.tailSway(at: t)))
        }
        XCTAssertEqual(sway, 8.0 * .pi / 180.0, accuracy: 0.001, "8 deg peak")
        var flutterMin = 1.0, flutterMax = 0.0
        for t in stride(from: 0.0, through: 3.0, by: 1.0 / 30.0) {
            let f = PuppetAmbient.flutter(at: t)
            flutterMin = min(flutterMin, f)
            flutterMax = max(flutterMax, f)
        }
        XCTAssertEqual(flutterMin, 0.01, accuracy: 0.001)
        XCTAssertEqual(flutterMax, 0.11, accuracy: 0.001)
        for t in stride(from: 0.0, through: 10.0, by: 1.0 / 30.0) {
            let micro = PuppetAmbient.pupilMicro(at: t)
            XCTAssertLessThanOrEqual(abs(micro.x), 0.0751, "micro jitter stays sub-glance")
            XCTAssertLessThanOrEqual(abs(micro.y), 0.0601)
        }
    }

    func testAmbientApplyFullVsLidsOnly() {
        var poseFull = PuppetPose()
        PuppetAmbient.apply(to: &poseFull, at: 0.9, full: true)
        XCTAssertEqual(Double(poseFull.bodyScaleY), PuppetAmbient.breathe(at: 0.9).bodyScaleY,
                       accuracy: 1e-6, "the breath multiplies the body scale")
        XCTAssertEqual(Double(poseFull.headOffsetY), PuppetAmbient.breathe(at: 0.9).headBobY,
                       accuracy: 1e-6, "the head counter-bobs")

        var poseLids = PuppetPose()
        PuppetAmbient.apply(to: &poseLids, at: 0.9, full: false)
        XCTAssertEqual(poseLids.bodyScaleY, 1, "Reduce Motion L2 pins the body")
        XCTAssertEqual(poseLids.headOffsetY, 0)
        XCTAssertEqual(poseLids.lean, 0)
        // The face keeps micro life at 35% amplitude.
        XCTAssertNotEqual(poseLids.pupilX, 0)
        XCTAssertNotEqual(poseLids.pupilY, 0)
    }
}
