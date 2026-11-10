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
}
