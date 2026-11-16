import XCTest
import CoreGraphics
@testable import Aivatar_Watch_App

/// v1.1 StageZoneTests: the live-stage three-zone layout (doc §5.11) and the
/// silhouette quiz (doc §5.12.2). The stage is header 18% / stage 56% /
/// dock 26%; the character's worst-case art bounds must stay INSIDE the
/// stage zone with >= 10% lateral breathing room on every watch canvas —
/// that is what makes a caption/art collision structurally impossible
/// (the name caption itself is deleted from the live stage). The
/// silhouette quiz renders each companion at icon size and requires the
/// five black silhouettes to be pairwise distinct: no "three rabbits".
final class StageZoneTests: XCTestCase {

    private let watchCanvases = [
        CGSize(width: 324, height: 394),  // 40 mm
        CGSize(width: 352, height: 430),  // 41 mm
        CGSize(width: 396, height: 484),  // 46 mm
    ]

    /// The art bounds (worst-case growth + hop) mapped to canvas space must
    /// never enter the header (top 18%) or the dock (bottom 26%), and keep
    /// >= 10% lateral breathing room.
    func testArtBoundsStayInsideStageZoneOnEveryWatchCanvas() {
        for archetype in Archetype.allCases {
            let spec = CompanionToys.spec(for: archetype)
            for canvas in watchCanvases {
                let layout = PuppetDrawing.Layout.fitZoned(canvas: canvas, spec: spec)
                let bounds = PuppetDrawing.artBounds(spec: spec, growth: 1.05, hop: 70)
                let t = layout.deviceTransform
                let tl = CGPoint(x: bounds.minX, y: bounds.minY).applying(t)
                let br = CGPoint(x: bounds.maxX, y: bounds.maxY).applying(t)
                XCTAssertGreaterThanOrEqual(tl.y, canvas.height * 0.18 - 0.5,
                    "\(archetype.rawValue) @\(Int(canvas.width))x\(Int(canvas.height)): art enters the header zone")
                XCTAssertLessThanOrEqual(br.y, canvas.height * 0.74 + 0.5,
                    "\(archetype.rawValue) @\(Int(canvas.width))x\(Int(canvas.height)): art enters the dock zone")
                XCTAssertGreaterThanOrEqual(tl.x, canvas.width * 0.10 - 0.5,
                    "\(archetype.rawValue) @\(Int(canvas.width))x\(Int(canvas.height)): < 10% left breathing room")
                XCTAssertLessThanOrEqual(br.x, canvas.width * 0.90 + 0.5,
                    "\(archetype.rawValue) @\(Int(canvas.width))x\(Int(canvas.height)): < 10% right breathing room")
            }
        }
    }

    /// The caption dock occupies the bottom 26%; with the art confined to the
    /// stage zone, a caption rect there can never intersect the art — the
    /// anti-collision contract as a unit test.
    func testDockCaptionZoneNeverIntersectsArtBounds() {
        for archetype in Archetype.allCases {
            let spec = CompanionToys.spec(for: archetype)
            for canvas in watchCanvases {
                let layout = PuppetDrawing.Layout.fitZoned(canvas: canvas, spec: spec)
                let bounds = PuppetDrawing.artBounds(spec: spec, growth: 1.05, hop: 70)
                let t = layout.deviceTransform
                let tl = CGPoint(x: bounds.minX, y: bounds.minY).applying(t)
                let br = CGPoint(x: bounds.maxX, y: bounds.maxY).applying(t)
                let dockTop = canvas.height * 0.74
                XCTAssertLessThanOrEqual(br.y, dockTop + 0.5,
                    "\(archetype.rawValue) @\(Int(canvas.width))x\(Int(canvas.height)): art intersects the dock caption zone")
                XCTAssertGreaterThanOrEqual(tl.y, canvas.height * 0.18 - 0.5,
                    "\(archetype.rawValue): art intersects the header zone")
            }
        }
    }

    // MARK: - The silhouette quiz (doc §5.12.2: the 40 px black-silhouette test)

    /// Renders the companion's neutral pose at `size` px onto a transparent
    /// bitmap and returns the alpha mask (CG row = canvas y, no extra flip).
    private func silhouette(_ archetype: Archetype, size: Int = 48) -> [Bool] {
        let spec = CompanionToys.spec(for: archetype)
        let canvas = CGSize(width: size, height: size)
        let bytesPerRow = size * 4
        guard let ctx = CGContext(data: nil, width: size, height: size,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return []
        }
        let layout = PuppetDrawing.Layout.fitZoned(canvas: canvas, spec: spec)
        let device = PuppetDrawing.CGSurface.flip(height: CGFloat(size))
            .concatenating(layout.deviceTransform)
        let drive = PuppetDrive(archetype: archetype, frameID: "idle")
        let (pose, props) = PuppetPoser.resolve(drive)
        PuppetDrawing.draw(PuppetDrawing.CGSurface(cg: ctx, device: device),
                           spec: spec, pose: pose, props: props,
                           style: .flat, time: 0)
        guard let data = ctx.data else { return [] }
        let ptr = data.assumingMemoryBound(to: UInt8.self)
        var mask = [Bool](repeating: false, count: size * size)
        for i in 0..<(size * size) {
            mask[i] = ptr[i * 4 + 3] > 127
        }
        return mask
    }

    /// At icon size every silhouette must paint a real figure, and every
    /// pair of the FIVE companions must be distinguishable from the black
    /// silhouette alone — a first-time viewer names the species, and no two
    /// read as the same animal (the "three rabbits" failure).
    func testSilhouetteQuizAtIconSize() {
        let size = 48
        let pets: [Archetype] = [.ember, .willow, .compass, .prism, .nimbus]
        var masks: [Archetype: [Bool]] = [:]
        for archetype in Archetype.allCases {
            let mask = silhouette(archetype, size: size)
            let painted = mask.filter { $0 }.count
            XCTAssertGreaterThan(painted, 45,
                "\(archetype.rawValue): the silhouette must paint a real figure at 48 px")
            masks[archetype] = mask
        }
        for i in 0..<pets.count {
            for j in (i + 1)..<pets.count {
                let a = pets[i], b = pets[j]
                let ma = masks[a]!, mb = masks[b]!
                var diff = 0
                for k in 0..<(size * size) where ma[k] != mb[k] { diff += 1 }
                XCTAssertGreaterThanOrEqual(diff, 60,
                    "\(a.rawValue) vs \(b.rawValue): silhouettes read as the same animal at 48 px (only \(diff) px differ)")
            }
        }
    }

    /// v1.3 §5.14A acceptance: the species quiz WITH A RABBIT AS THE
    /// DISTRACTOR — a synthetic bunny (round head + tall narrow parallel
    /// crown ears) must NOT match any companion at 48 px.
    func testNoCompanionReadsAsTheRabbitDistractor() {
        let size = 48
        // The rabbit: head blob + two tall narrow parallel ears on the crown.
        var rabbitPts: [CGPoint] = []
        rabbitPts += PuppetDrawing.blobPoints(cx: 24, cy: 30, rx: 11, ry: 10.5,
                                              harmonics: [(0.03, 2, 0.0)])
        let rabbitPath = PuppetDrawing.smoothClosedPath(points: rabbitPts)
        var earPts: [CGPoint] = []
        for x in [18.5, 29.5] {
            earPts += PuppetDrawing.blobPoints(cx: x, cy: 13, rx: 3.6, ry: 11,
                                               harmonics: [(0.06, 2, 0.5)])
        }
        let earPath = PuppetDrawing.smoothClosedPath(points: earPts)
        let bpr = size * 4
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: bpr, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return XCTFail("no bitmap")
        }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.addPath(rabbitPath); ctx.fillPath()
        ctx.addPath(earPath); ctx.fillPath()
        guard let data = ctx.data else { return XCTFail("no data") }
        let ptr = data.assumingMemoryBound(to: UInt8.self)
        var rabbit = [Bool](repeating: false, count: size * size)
        for i in 0..<(size * size) { rabbit[i] = ptr[i * 4 + 3] > 127 }

        let pets: [Archetype] = [.ember, .willow, .compass, .prism, .nimbus]
        for a in pets {
            let m = silhouette(a, size: size)
            var diff = 0
            for k in 0..<(size * size) where m[k] != rabbit[k] { diff += 1 }
            XCTAssertGreaterThanOrEqual(diff, 60,
                "\(a.rawValue): reads as the RABBIT at 48 px (only \(diff) px differ from the distractor)")
        }
    }
}
