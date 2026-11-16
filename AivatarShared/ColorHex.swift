import Foundation

/// ColorHex (v3 shared): the palette math the authored raster grammar kept
/// in CompanionSprite for 40+ versions — moved out so the character layer
/// (AivatarShared/CompanionToy.swift) owns it. Pure, byte-stable helpers.
nonisolated enum ColorHex {

    /// Parses a 6-digit hex string (with or without '#') into 8-bit RGB.
    nonisolated static func rgb(_ hex: String) -> (r: UInt8, g: UInt8, b: UInt8) {
        var value: UInt64 = 0
        var digits: [UInt64] = []
        for c in hex where c.isHexDigit {
            if let d = UInt64(String(c), radix: 16) { digits.append(d) }
        }
        if digits.count >= 6 {
            value = (digits[digits.count - 6] << 20) | (digits[digits.count - 5] << 16)
                    | (digits[digits.count - 4] << 12) | (digits[digits.count - 3] << 8)
                    | (digits[digits.count - 2] << 4) | digits[digits.count - 1]
        }
        return (UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF))
    }

    /// Formats 8-bit RGB into a 6-digit hex string.
    nonisolated static func hex(r: UInt8, g: UInt8, b: UInt8) -> String {
        String(format: "%02X%02X%02X", r, g, b)
    }

    /// Rotates a palette hex's hue by `degrees` (HSV space, saturation and
    /// value preserved — a value-locked ramp keeps its luminance ordering).
    /// v18 F3: Prism's temperature swings ride this; 0/360 = identity.
    nonisolated static func hueRotated(_ source: String, degrees: Double) -> String {
        let (r, g, b) = rgb(source)
        let rf = Double(r) / 255, gf = Double(g) / 255, bf = Double(b) / 255
        let vMax = max(rf, gf, bf), vMin = min(rf, gf, bf)
        let d = vMax - vMin
        var h = 0.0
        if d > 0 {
            if vMax == rf { h = (gf - bf) / d + (gf < bf ? 6 : 0) }
            else if vMax == gf { h = (bf - rf) / d + 2 }
            else { h = (rf - gf) / d + 4 }
            h *= 60
        }
        let s = vMax == 0 ? 0 : d / vMax
        var nh = (h + degrees).truncatingRemainder(dividingBy: 360)
        if nh < 0 { nh += 360 }
        let c = d
        let x = c * (1 - abs(nh.truncatingRemainder(dividingBy: 120) / 60 - 1))
        let m = vMin
        var rgbv: (Double, Double, Double)
        switch nh {
        case 0..<60: rgbv = (c, x, 0)
        case 60..<120: rgbv = (x, c, 0)
        case 120..<180: rgbv = (0, c, x)
        case 180..<240: rgbv = (0, x, c)
        case 240..<300: rgbv = (x, 0, c)
        default: rgbv = (c, 0, x)
        }
        func to8(_ v: Double) -> UInt8 {
            UInt8(min(255, max(0, (v + m) * 255)).rounded())
        }
        return String(format: "%02X%02X%02X", to8(rgbv.0), to8(rgbv.1), to8(rgbv.2))
    }

    /// Linear mix of two hexes (0 = a, 1 = b) — the toy shading's only blend
    /// (2-tone depth, never a full ramp).
    nonisolated static func mix(_ a: String, _ b: String, t: Double) -> String {
        let ta = rgb(a), tb = rgb(b)
        let f = min(1, max(0, t))
        return String(
            format: "%02X%02X%02X",
            UInt8((1 - f) * Double(ta.r) + f * Double(tb.r)),
            UInt8((1 - f) * Double(ta.g) + f * Double(tb.g)),
            UInt8((1 - f) * Double(ta.b) + f * Double(tb.b)))
    }

    /// The rest-LOD dim factor for a family token: paper keeps a little more
    /// light than the rest (the v12 persistent-display rest grammar).
    nonisolated static let restLightFactor = 0.30
    nonisolated static let restDimFactor = 0.22
}

/// RGBA double (0...1) — the painter's unit of color across the Canvas and
/// CGContext backends (one type, two surfaces, zero drift).
nonisolated struct RGBA: Sendable, Equatable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    nonisolated init(_ hex: String, alpha: Double = 1) {
        let c = ColorHex.rgb(hex)
        r = Double(c.r) / 255
        g = Double(c.g) / 255
        b = Double(c.b) / 255
        a = alpha
    }

    nonisolated init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    nonisolated func withAlpha(_ alpha: Double) -> RGBA {
        RGBA(r: r, g: g, b: b, a: alpha)
    }

    /// The rest-LOD dim (paper keeps 0.30, everything else 0.22 — the
    /// Always-On grammar the pixel stage already shipped).
    nonisolated var restDimmed: RGBA {
        let f = isPaperish ? ColorHex.restLightFactor : ColorHex.restDimFactor
        return RGBA(r: r * f, g: g * f, b: b * f, a: a)
    }

    /// "Paper" = near-white belly tones (luminance >= 0.82).
    private var isPaperish: Bool {
        0.2126 * r + 0.7152 * g + 0.0722 * b >= 0.82
    }
}
