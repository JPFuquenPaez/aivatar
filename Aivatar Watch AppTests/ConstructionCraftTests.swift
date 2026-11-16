import XCTest
import CoreGraphics
@testable import Aivatar_Watch_App

/// v1.2 §5.13 acceptance tests for the construction craft layer: every
/// major part contour must deviate from a perfect primitive (the
/// contour-deviation rule), and parts must overlap decisively at the joints
/// (zero tangent contacts). The silhouette quiz in StageZoneTests pins that
/// the re-construction still passes at 40 px.
final class ConstructionCraftTests: XCTestCase {

    /// Max radial deviation from the mean radius, sampled on the authored
    /// anchor points of a closed contour (pure math — no rasterizing).
    private func maxDeviation(_ pts: [CGPoint]) -> CGFloat {
        let cx = pts.map { $0.x }.reduce(0, +) / CGFloat(pts.count)
        let cy = pts.map { $0.y }.reduce(0, +) / CGFloat(pts.count)
        let radii = pts.map { hypot($0.x - cx, $0.y - cy) }
        let mean = radii.reduce(0, +) / CGFloat(radii.count)
        return radii.map { abs($0 - mean) / mean }.max() ?? 0
    }

    /// Rule 5.13.2: head and body contours deviate from a circle/ellipse in
    /// at least two places — pinned numerically at >= 3% max radial deviation.
    func testHeadAndBodyAreAuthoredContoursNotPrimitives() {
        for archetype in Archetype.allCases {
            let spec = CompanionToys.spec(for: archetype)
            let headDev = maxDeviation(PuppetDrawing.headPoints(cx: 500, cy: 400, d: spec.headDiameter))
            XCTAssertGreaterThanOrEqual(headDev, 0.03,
                "\(archetype.rawValue): head contour is too close to a circle (\(headDev))")
            let bodyDev = maxDeviation(PuppetDrawing.bodyPoints(spec))
            XCTAssertGreaterThanOrEqual(bodyDev, 0.03,
                "\(archetype.rawValue): body contour is too close to an ellipse (\(bodyDev))")
        }
    }

    /// Rule 5.13.3: zero tangent contacts — the head mass settles OVER the
    /// body, and the ears sink INTO the head, with real overlap depth.
    func testPartsOverlapDecisivelyAtTheJoints() {
        for archetype in Archetype.allCases {
            let spec = CompanionToys.spec(for: archetype)
            // Head-over-body: the chin dips into the chest mass.
            let headBottom = 400 + spec.headDiameter / 2
            let bodyTop = 700 - spec.bodyHeight / 2
            XCTAssertGreaterThanOrEqual(headBottom - bodyTop, 30,
                "\(archetype.rawValue): head and body are tangent or apart (overlap \(headBottom - bodyTop))")
            // Ears-over-head: the ear base is buried a quarter of its height.
            if spec.earHeight > 0 {
                let baseY = 400 - spec.headDiameter * 0.42
                let earBottom = baseY + spec.earHeight * 0.25
                let headTop = 400 - spec.headDiameter / 2
                XCTAssertGreaterThan(earBottom - headTop, 10,
                    "\(archetype.rawValue): ear touches the head tangentially")
            }
        }
    }
}
