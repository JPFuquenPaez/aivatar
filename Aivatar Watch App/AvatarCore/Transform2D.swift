import Foundation

/// 2D affine transform with `Float` components (CoreGraphics-free so the engine
/// stays decoupled from any UI framework and bit-exact on any device).
///
/// Layout matches CGAffineTransform: `x' = a*x + c*y + tx`, `y' = b*x + d*y + ty`.
/// A zero rotation has `a = d = 1`, pointing along -Y (up on screen).
nonisolated struct Transform2D: Sendable, Equatable {
    var a: Float = 1
    var b: Float = 0
    var c: Float = 0
    var d: Float = 1
    var tx: Float = 0
    var ty: Float = 0

    static let identity = Transform2D()

    /// `t.appended(u)` returns the transform equivalent to applying `u` first,
    /// then `t`. Forward kinematics uses `world = parent.appended(local)`.
    func appended(_ other: Transform2D) -> Transform2D {
        Transform2D(
            a: a * other.a + c * other.b,
            b: b * other.a + d * other.b,
            c: a * other.c + c * other.d,
            d: b * other.c + d * other.d,
            tx: a * other.tx + c * other.ty + tx,
            ty: b * other.tx + d * other.ty + ty
        )
    }

    static func translation(x: Float, y: Float) -> Transform2D {
        Transform2D(tx: x, ty: y)
    }

    /// Radians, screen convention (positive = clockwise on screen).
    static func rotation(_ radians: Float) -> Transform2D {
        let s = sin(radians)
        let c = cos(radians)
        return Transform2D(a: c, b: s, c: -s, d: c)
    }

    static func scale(x: Float, y: Float) -> Transform2D {
        Transform2D(a: x, d: y)
    }

    func applying(x: Float, y: Float) -> (x: Float, y: Float) {
        (a * x + c * y + tx, b * x + d * y + ty)
    }

    /// Local bone-space transform: translate by the bone offset, then rotate.
    static func local(offsetX: Float, offsetY: Float, rotation: Float, scaleX: Float, scaleY: Float) -> Transform2D {
        translation(x: offsetX, y: offsetY)
            .appended(Transform2D.rotation(rotation))
            .appended(Transform2D.scale(x: scaleX, y: scaleY))
    }
}
