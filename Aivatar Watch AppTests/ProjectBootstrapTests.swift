import XCTest
import SwiftUI
@testable import Aivatar_Watch_App

final class ProjectBootstrapTests: XCTestCase {
    func testBundleLoads() {
        XCTAssertNotNil(Bundle(for: ProjectBootstrapTests.self))
    }

    /// Aivatar 2.0 E1: AccentColor must be populated in the asset catalog and
    /// match Ember's accent token (paletteHex["A"] = FFC800) within 1/255 per
    /// channel, so system-tinted chrome never flashes a foreign hue.
    func testAccentColorIsEmberAccent() {
        let color = Color("AccentColor")
        let ns = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        XCTAssertTrue(ns.getRed(&r, green: &g, blue: &b, alpha: &a), "AccentColor must resolve in the app bundle")
        let target = IconCuts.emberFacePaletteHex["A"]!  // "FFC800" — the icon ramp, hash-pinned
        let rgb = ColorHex.rgb(target)
        XCTAssertLessThanOrEqual(abs(Float(r) - Float(rgb.r) / 255), 1.0 / 255, "red channel off")
        XCTAssertLessThanOrEqual(abs(Float(g) - Float(rgb.g) / 255), 1.0 / 255, "green channel off")
        XCTAssertLessThanOrEqual(abs(Float(b) - Float(rgb.b) / 255), 1.0 / 255, "blue channel off")
    }
}
