import Foundation

/// PetMotion (v43, AMS v2 §5.8): the ENVELOPE LIBRARY that feeds the
/// CellQuantizer — continuous math INSIDE the generator only; every value
/// crosses the cell floor before it is ever drawn. The v42 whole-image
/// transform layer (sub-cell sway/rotation, the whole-body scaleY blink, the
/// 0.8-cell body-slide glance, crop-rotation puppet redraw) is deleted from
/// every surface (the kill list): motion on the grid is authored poses and
/// quantized part steps, nothing else.
///
/// What survives here:
/// - `tailProposal(age:)` — the ambient tail-wag envelope (a full
///   swing-and-settle over one burst), proposed in CELLS and stepped by
///   CellQuantizer with the >=2-tick hold rule (TailChannel).
nonisolated enum PetMotion {

    /// The wag burst envelope, in cells. One full left-right-left swing over
    /// `TailChannel.burstTicks` ages: rises to ~1.4 cells, settles through
    /// neutral, swings the other way — a wag, not a tick.
    static func tailProposal(age: Int) -> Double {
        guard age > 0 else { return 0 }
        return 1.4 * sin(2.0 * .pi * Double(age) / 4.0)
    }
}
