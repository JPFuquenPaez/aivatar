import XCTest
import CoreGraphics
@testable import Aivatar_Watch_App

/// Aivatar 2.0 E9 (v3) — the ground shadow and the cold-breath vapor on the
/// puppet stage. The shadow (E9.1) is a soft ellipse under the feet: drawn
/// in every awake scan, silent in the rest LOD (the stage's farewell dim
/// ramp suppresses everything visually, so no drawing gate is needed), and
/// its contact swells with squash-and-stretch — the v43 tile's "inhale on
/// the breathe frame" carried into vector physics. The vapor (E9.2) rides
/// the director's schedule and the drive's PROPS only — never a pose
/// channel: the body never moves for weather.
final class SeasonOverlayTests: XCTestCase {

    /// Renders one flat scan onto a mid-gray stage (the shadow is a dark
    /// ellipse: invisible on OLED black, obvious on gray) and returns the
    /// bytes plus the shadow's device band rows.
    private func render(archetype: Archetype, style: PuppetStyle = .flat,
                        modify: (inout PuppetDrive) -> Void = { _ in }) -> ([UInt8], Int, Int, ClosedRange<Int>) {
        let w = 200, h = 320
        let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let layout = PuppetDrawing.Layout.fit(canvas: CGSize(width: w, height: h), scaleFactor: 0.92)
        let device = layout.deviceTransform.concatenating(PuppetDrawing.CGSurface.flip(height: CGFloat(h)))
        let surface = PuppetDrawing.CGSurface(cg: ctx, device: device)
        var drive = PuppetDrive(archetype: archetype, frameID: "idle")
        modify(&drive)
        let (pose, props) = PuppetPoser.resolve(drive)
        PuppetDrawing.draw(surface, spec: CompanionToys.spec(for: archetype),
                           pose: pose, props: props, style: style, time: 0.7)
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let rctx = CGContext(
            data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        rctx.draw(ctx.makeImage()!, in: CGRect(x: 0, y: 0, width: w, height: h))
        let top = Int(CGPoint(x: 500, y: 872 - 17).applying(layout.deviceTransform).y.rounded())
        let bottom = Int(CGPoint(x: 500, y: 872 + 17).applying(layout.deviceTransform).y.rounded())
        return (data, w, h, max(0, top)...min(h - 1, bottom))
    }

    /// Dark pixels in the shadow band, canvas x 45...70 — LEFT of the feet
    /// (feet start at author x ~339): only the shadow reaches there. The
    /// threshold is RELATIVE to the gray stage fill (the shadow is a 0.22
    /// black wash — about 12% below the background).
    private func shadowPixels(_ r: ([UInt8], Int, Int, ClosedRange<Int>), x0: Int = 45, x1: Int = 70) -> Int {
        let (data, w, h, band) = r
        let bgO = ((h - 2) * w + 2) * 4
        let bg = Int(data[bgO])
        var count = 0
        for y in band {
            for x in x0...x1 {
                let o = (y * w + x) * 4
                if data[o] < bg - 12 && data[o + 1] < bg - 12 { count += 1 }
            }
        }
        return count
    }

    private func leftmostShadow(_ r: ([UInt8], Int, Int, ClosedRange<Int>), x0: Int = 30, x1: Int = 60) -> Int {
        let (data, w, h, band) = r
        let bgO = ((h - 2) * w + 2) * 4
        let bg = Int(data[bgO])
        for x in x0...x1 {
            for y in band where data[(y * w + x) * 4] < bg - 12 { return x }
        }
        return x1 + 1
    }

    func testShadowUnderEveryAwakeDraw() {
        // E9.1: present under every species' idle scan (v35 parity).
        for archetype in Archetype.allCases {
            let r = render(archetype: archetype)
            XCTAssertGreaterThanOrEqual(shadowPixels(r), 8,
                                         "\(archetype): the ground shadow paints")
        }
    }

    func testShadowAbsentInRestLOD() {
        // The rest scan draws NO shadow (the guard is style .rest) and the
        // dim feet start at author x~339, outside the measured zone.
        for archetype in Archetype.allCases {
            let r = render(archetype: archetype, style: .rest,
                           modify: { $0.resting = true })
            XCTAssertEqual(shadowPixels(r), 0,
                           "\(archetype): rest LOD keeps the band empty")
        }
    }

    func testShadowScalesWithSquashAndStretch() {
        // The contact widens when the body squashes (the boop pulse is the
        // extreme case: bodyScaleY 0.88, bodyScaleX 1.10 -> sway ~1.16).
        let idle = render(archetype: .ember)
        let boop = render(archetype: .ember, modify: { $0.boopPulse = true })
        XCTAssertGreaterThanOrEqual(shadowPixels(boop), shadowPixels(idle),
                                    "the squashed contact covers more of the band")
        XCTAssertLessThanOrEqual(leftmostShadow(boop) + 4, leftmostShadow(idle),
                                 "the widened shadow pokes further left than the idle contact")
    }

    // MARK: - E9.2 cold breath vapor

    private func director(_ archetype: Archetype, seed: UInt64 = 20261010) throws -> SpriteDirector {
        let profile = try PersonalityProfile.load(archetype)
        return SpriteDirector(profile: profile, seed: seed)
    }

    func testVaporOnlyWhenCold() throws {
        for archetype in Archetype.allCases {
            let d = try director(archetype)
            d.setCondition(.sunny)
            var puffs = 0
            for t in 1...1000 {
                d.advance(toTick: t)
                if d.vaporActive { puffs += 1 }
            }
            XCTAssertEqual(puffs, 0, "\(archetype): sunny never vaporizes")
            d.setCondition(.unknown)
            for t in 1001...2000 { d.advance(toTick: t) }
            XCTAssertFalse(d.vaporActive, "\(archetype): unknown class never vaporizes (G8)")
        }
    }

    func testVaporScheduleStatisticsAndShape() throws {
        let d = try director(.ember)
        d.setCondition(.cold)
        var puffTicks: [Int] = []
        for t in 1...2000 {
            d.advance(toTick: t)
            if d.vaporActive { puffTicks.append(t) }
        }
        XCTAssertFalse(puffTicks.isEmpty, "cold weather produces vapor over 2000 ticks")
        // Puffs are exactly 3 contiguous ticks.
        var i = 0
        while i < puffTicks.count {
            let start = puffTicks[i]
            var len = 1
            while i + len < puffTicks.count, puffTicks[i + len] == start + len { len += 1 }
            XCTAssertEqual(len, SpriteDirector.vaporOnTicks, "puff at \(start) must be exactly 3 ticks")
            i += len
            // Gap to the next puff is >= 33 ticks.
            if i < puffTicks.count {
                XCTAssertGreaterThanOrEqual(puffTicks[i] - start, 3 + SpriteDirector.vaporMinHiddenTicks)
            }
        }
    }

    func testVaporRidesPropsOnlyPosesNeverChange() {
        // Weather never moves the body: the vapor channel changes PROPS only
        // (two ink blobs above the face); the resolved pose is bit-identical,
        // and the rest LOD suppresses the vapor entirely.
        for archetype in Archetype.allCases {
            let plain = PuppetDrive(archetype: archetype, frameID: "idle")
            var vapy = plain
            vapy.vapor = true
            let a = PuppetPoser.resolve(plain)
            let b = PuppetPoser.resolve(vapy)
            XCTAssertEqual(a.pose, b.pose, "\(archetype): vapor never touches the pose")
            XCTAssertFalse(a.props.vapor)
            XCTAssertTrue(b.props.vapor, "\(archetype): vapor rides the props")
            var resting = vapy
            resting.resting = true
            XCTAssertFalse(PuppetPoser.resolve(resting).props.vapor,
                           "\(archetype): rest LOD suppresses vapor")
        }
    }

    func testVaporDeterministicPerSeed() throws {
        func run() -> [Bool] {
            let d = try! director(.prism, seed: 424242)
            d.setCondition(.cold)
            var out: [Bool] = []
            for t in 1...500 { d.advance(toTick: t); out.append(d.vaporActive) }
            return out
        }
        XCTAssertEqual(run(), run())
    }

    func testVaporSuppressedInSession() throws {
        let d = try director(.nimbus)
        d.setCondition(.cold)
        d.setSessionMode(true)
        for t in 1...600 { d.advance(toTick: t) }
        XCTAssertFalse(d.vaporActive, "no vapor during a breath session")
        d.setSessionMode(false)
        for t in 601...1200 { d.advance(toTick: t) }
        XCTAssertFalse(d.vaporActive, "no vapor during a breath session")
    }
}
