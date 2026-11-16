import XCTest
import CoreGraphics
@testable import Aivatar_Watch_App

/// v3 PostcardCard (the share export, iPhone shell + watch moments): a
/// 1080x1080 pure-black card with the CLAY puppet as the hero (the same
/// poser + drawing path as the watch stage; growth and accessory ride the
/// bond level), the naming-day anniversary as three accent dots top-right,
/// captions centered at the bottom, and byte-deterministic output.
final class PostcardCardTests: XCTestCase {

    private func bytes(_ image: CGImage) -> ( UnsafePointer<UInt8>, Int )? {
        guard let data = image.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return nil }
        return (ptr, image.width)
    }

    func testCardIs1080SquareBlackWithClayHero() throws {
        let image = try XCTUnwrap(PostcardCard.render(archetype: .ember, title: "Ember", subtitle: "day 3 · awake"))
        XCTAssertEqual(image.width, 1080)
        XCTAssertEqual(image.height, 1080)
        let (b, w) = try XCTUnwrap(bytes(image))
        func px(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
            let o = (y * w + x) * 4
            return (b[o], b[o + 1], b[o + 2])
        }
        // Corners pure black.
        let corner = px(4, 4)
        XCTAssertTrue(corner.0 == 0 && corner.1 == 0 && corner.2 == 0, "corner stays pure black")
        // The head disc paints: author (500, 400) → device (~540, ~410) at
        // Layout.fit(1080, scaleFactor 0.80). Scan a real area, not a pixel.
        var painted = 0
        for y in 380...440 {
            for x in 500...580 where px(x, y).0 != 0 { painted += 1 }
        }
        XCTAssertGreaterThan(painted, 900, "the clay hero band paints")
        // The top margin survives (the ears start below y=88).
        var topInk = 0
        for x in 400...680 where px(x, 25).0 != 0 || px(x, 25).1 != 0 { topInk += 1 }
        XCTAssertEqual(topInk, 0, "top margin stays clean above the ears")
    }

    func testAnniversaryStampPaintsThreeAccentDotsTopRight() throws {
        let plain = try XCTUnwrap(PostcardCard.render(archetype: .ember, title: "Ember", subtitle: "day 3"))
        let stamped = try XCTUnwrap(PostcardCard.render(archetype: .ember, title: "Ember", subtitle: "day 3", anniversary: true))
        let (b, w) = try XCTUnwrap(bytes(stamped))
        let (pb, _) = try XCTUnwrap(bytes(plain))
        // Ember's art accent is leaf green 76C893: three 44-pt discs stacked
        // at the top-right corner (cols ~988...1032, memory rows ~48...208).
        func accentish(_ r: (UInt8, UInt8, UInt8)) -> Bool {
            abs(Int(r.0) - 118) < 40 && abs(Int(r.1) - 200) < 40 && abs(Int(r.2) - 147) < 40
        }
        var dots = 0
        for y in 44...212 {
            for x in 980...1040 {
                let o = (y * w + x) * 4
                if accentish((b[o], b[o + 1], b[o + 2])) { dots += 1 }
            }
        }
        XCTAssertGreaterThan(dots, 3000, "three accent discs paint the corner")
        // The plain card stays clean in the stamp zone.
        var plainInk = 0
        for y in 44...212 {
            for x in 980...1040 {
                let o = (y * w + x) * 4
                if pb[o] != 0 || pb[o + 1] != 0 { plainInk += 1 }
            }
        }
        XCTAssertEqual(plainInk, 0, "no stamp without the anniversary")
    }

    func testCardIsDeterministic() throws {
        let a = try XCTUnwrap(PostcardCard.pngData(archetype: .prism, title: "Prism", subtitle: "day 9 · napping"))
        let b = try XCTUnwrap(PostcardCard.pngData(archetype: .prism, title: "Prism", subtitle: "day 9 · napping"))
        XCTAssertEqual(a, b, "same inputs -> same PNG bytes")
    }

    func testCardCarriesGrowthAndFamilyIdentity() throws {
        // Bond level changes the card (growth scale + the accessory rung).
        let young = try XCTUnwrap(PostcardCard.pngData(archetype: .willow, title: "Willow", subtitle: "day 2", bondLevel: 1))
        let grown = try XCTUnwrap(PostcardCard.pngData(archetype: .willow, title: "Willow", subtitle: "day 2", bondLevel: 5))
        XCTAssertNotEqual(young, grown, "the companion visibly grows with the bond")
        // The family identity: ember renders different art than willow.
        let ember = try XCTUnwrap(PostcardCard.pngData(archetype: .ember, title: "Willow", subtitle: "day 2"))
        XCTAssertNotEqual(ember, young, "one character per family, not a template")
    }

    /// v33 regression intent carried to v3: captions are centered bottom and
    /// never touch the edges.
    func testCaptionsCenteredBottomAndClearOfEdges() throws {
        let image = try XCTUnwrap(PostcardCard.render(archetype: .compass, title: "Compass", subtitle: "day 2 · awake"))
        let (b, w) = try XCTUnwrap(bytes(image))
        func painted(_ x: Int, _ y: Int) -> Bool {
            let o = (y * w + x) * 4
            return b[o] != 0 || b[o + 1] != 0 || b[o + 2] != 0
        }
        func paintedInBand(_ y0: Int, _ y1: Int, _ x0: Int, _ x1: Int) -> Bool {
           for y in y0...y1 { for x in stride(from: x0, through: x1, by: 2) where painted(x, y) { return true } }
           return false
        }
        // Title baseline at 0.82*1080 (56 pt) -> glyphs ~820...880 incl.
        // descenders; subtitle +64 px (36 pt) -> ~905...950. A gutter
        // separates hero and captions.
        XCTAssertTrue(paintedInBand(820, 880, 420, 660), "title is centered on its band")
        XCTAssertTrue(paintedInBand(905, 950, 420, 660), "subtitle is centered on its band")
        XCTAssertFalse(paintedInBand(820, 950, 1060, 1078), "no caption reaches the right edge")
        XCTAssertFalse(paintedInBand(820, 950, 0, 18), "no caption reaches the left edge")
        XCTAssertFalse(paintedInBand(884, 902, 300, 780), "a gutter separates hero and captions")
    }
}
