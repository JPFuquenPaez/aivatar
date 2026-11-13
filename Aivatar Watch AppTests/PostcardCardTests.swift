import XCTest
import CoreGraphics
@testable import Aivatar_Watch_App

/// Aivatar 2.0 Phase 3 — PostcardCard (the iPhone shell's share export).
/// The renderer lives in AivatarShared (compiled into watch app, widget, and
/// iPhone shell alike), so it is pinned here: 1080x1080 black canvas,
/// nearest-neighbor icon upscale, caption drawn, deterministic bytes.
final class PostcardCardTests: XCTestCase {

    func testCardIs1080SquareBlackCanvasWithIcon() throws {
        let icon = try XCTUnwrap(CompanionIcon.pngData(for: .ember))
        let image = try XCTUnwrap(PostcardCard.render(iconPNG: icon, title: "Ember", subtitle: "day 3 · awake"))
        XCTAssertEqual(image.width, 1080)
        XCTAssertEqual(image.height, 1080)
        // Corner pixels are pure black; the icon area is not.
        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return XCTFail("no pixel data") }
        func px(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
            let o = (y * 1080 + x) * 4
            return (bytes[o], bytes[o + 1], bytes[o + 2])
        }
        let corner = px(4, 4)
        XCTAssertTrue(corner.0 == 0 && corner.1 == 0 && corner.2 == 0, "corner stays pure black")
        let center = px(540, 300)
        XCTAssertFalse(center.0 == 0 && center.1 == 0 && center.2 == 0, "icon area is painted")
    }

    func testCardIsDeterministic() throws {
        let icon = try XCTUnwrap(CompanionIcon.pngData(for: .prism))
        let a = try XCTUnwrap(PostcardCard.pngData(iconPNG: icon, title: "Prism", subtitle: "day 9 · napping"))
        let b = try XCTUnwrap(PostcardCard.pngData(iconPNG: icon, title: "Prism", subtitle: "day 9 · napping"))
        XCTAssertEqual(a, b, "same inputs -> same PNG bytes")
    }

    func testCardRendersWithoutIcon() {
        // No snapshot icon yet: caption-only card still renders.
        XCTAssertNotNil(PostcardCard.pngData(iconPNG: nil, title: "Ember", subtitle: "day 1 · awake"))
    }

    func testCardVariesWithCaption() throws {
        let icon = try XCTUnwrap(CompanionIcon.pngData(for: .willow))
        let a = try XCTUnwrap(PostcardCard.pngData(iconPNG: icon, title: "Willow", subtitle: "day 2 · awake"))
        let b = try XCTUnwrap(PostcardCard.pngData(iconPNG: icon, title: "Willow", subtitle: "day 2 · napping"))
        XCTAssertNotEqual(a, b)
    }

    /// v33 regression: the icon must keep a top margin (fit-to-box, not a
    /// fixed scale flush with the canvas edge) and the subtitle must be
    /// centered under the title — the CTM used to accumulate between
    /// captions, pushing the subtitle off the right edge.
    func testCardCompositionMarginsAndCenteredCaptions() throws {
        let icon = try XCTUnwrap(CompanionIcon.pngData(for: .willow))
        let image = try XCTUnwrap(PostcardCard.render(iconPNG: icon, title: "Willow", subtitle: "day 2 · awake"))
        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return XCTFail("no pixel data") }
        func px(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
            let o = (y * 1080 + x) * 4
            return (bytes[o], bytes[o + 1], bytes[o + 2])
        }
        func painted(_ p: (UInt8, UInt8, UInt8)) -> Bool {
            p.0 != 0 || p.1 != 0 || p.2 != 0
        }
        // Top margin: the fitted icon starts below y=20 at center-x.
        XCTAssertFalse(painted(px(540, 20)), "icon keeps a top margin")
        // Caption bands (y-down): title glyphs ~784..823, subtitle ~869..894.
        // Centered => painted near center-x in the band; and nothing may
        // touch the right edge (the v33 bug pushed the subtitle off-canvas).
        func paintedInBand(_ y0: Int, _ y1: Int, _ x0: Int, _ x1: Int) -> Bool {
            for y in y0...y1 where y < 1080 {
                for x in stride(from: x0, through: x1, by: 2) where painted(px(x, y)) { return true }
            }
            return false
        }
        XCTAssertTrue(paintedInBand(784, 823, 400, 680), "title is centered on its band")
        XCTAssertTrue(paintedInBand(869, 894, 400, 680), "subtitle is centered on its band")
        XCTAssertFalse(paintedInBand(784, 894, 1060, 1078), "no caption reaches the right edge")
        XCTAssertFalse(paintedInBand(784, 894, 0, 18), "no caption reaches the left edge")
    }
}
