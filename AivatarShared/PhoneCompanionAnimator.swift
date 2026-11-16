import Foundation

/// PhoneCompanionAnimator (v36): the iPhone shell's living avatar. It runs the
/// SAME authored 20x18 sprite (AivatarShared.CompanionSprite — the exact grids
/// the watch renders) on the SAME 150 ms director clock, with the same life
/// floor (breathe 4-tick hold every 24 ticks), idle drift, blink, glance and
/// quirk — so the companion on the phone is the same animal doing the same
/// things as on the watch. Pure and deterministic: every stochastic draw comes
/// from one SplitMix64 stream seeded per archetype XOR a private constant
/// (house rule), so same (seed, tick) -> same frame, pinned by tests.
///
/// The phone never polls the watch: the snapshot only supplies identity and
/// presence; all motion is computed locally from the tick.
nonisolated final class PhoneCompanionAnimator: @unchecked Sendable {
    let archetype: Archetype
    let presence: CompanionPresence
    private(set) var tick = 0
    private var rng: SeededRandom
    private var queue: [(frame: String, ticks: Int)] = []
    private(set) var currentFrame = "idle"
    /// Ticks the current frame has been showing (act envelopes key on this).
    private(set) var frameAge = 0
    /// AMS v2 (v43): the ambient tail channel — the same PetMotion envelope
    /// -> CellQuantizer -> authored pose path as the watch stage, on its own
    /// stream, so the phone's companion wags the same way (deterministic per
    /// archetype seed).
    private var tailChannel: TailChannel
    var tailPose: Int { tailChannel.pose }
    var tailOverlayCells: [CompanionSprite.CellDiff] {
        SpriteStageMetadata.tailOverlay(archetype, pose: tailChannel.pose)
    }
    /// The animator's dedicated stream seed (PetMotion pose phases derive from it).
    var seed: UInt64 { Self.phoneSeed(archetype) }

    /// The stage's per-archetype base seed (same constant the watch uses),
    /// XOR a private constant for the phone's dedicated stream.
    static func phoneSeed(_ archetype: Archetype) -> UInt64 {
        let base = 20261010 + UInt64(Archetype.allCases.firstIndex(of: archetype) ?? 0)
        return base ^ 0xBEEF_1A11
    }

    init(archetype: Archetype, presence: CompanionPresence = .awake) {
        self.archetype = archetype
        self.presence = presence
        self.rng = SeededRandom(Self.phoneSeed(archetype))
        self.tailChannel = TailChannel(seed: Self.phoneSeed(archetype))
    }

    /// Advances the clock to `target` ticks (idempotent).
    func advance(toTick target: Int) {
        while tick < target { step() }
    }

    private func step() {
        let before = currentFrame
        tick += 1
        stepBody()
        frameAge = (currentFrame == before) ? frameAge + 1 : 1
    }

    private func stepBody() {
        // AMS v2: the tail part steps every tick — awake + alive only
        // (asleep and events stay calm; Random Motion freezes upstream).
        _ = tailChannel.step(modeAllows: presence == .awake,
                             ticksPerMinute: 400, tempoScale: 1)
        // Asleep: the rest face with a slow blink only.
        if presence == .asleep {
            if queue.isEmpty {
                if tick % 60 == 0 { queue.append(("blink", 2)) }
                else { currentFrame = "sleepy" }
            }
            if !queue.isEmpty { dequeue() }
            return
        }
        // The life floor wins over any queued act: breathe 4 ticks every 24
        // (600 ms hold / 3.6 s), exactly like the watch's floor.
        if tick % 24 < 4 { queue.removeAll(); currentFrame = "breathe"; return }
        if queue.isEmpty {
            // Fixed draw order per tick (deterministic): blink, glance, quirk, drift.
            if rng.nextInt(30) == 0 { queue.append(("blink", 2)) }
            else if rng.nextInt(60) == 0 { queue.append((rng.nextInt(2) == 0 ? "glanceL" : "glanceR", 3)) }
            else if presence == .event, rng.nextInt(90) == 0 { queue.append(("quirk", 12)) }
            else if presence == .awake, rng.nextInt(240) == 0 { queue.append(("quirk", 12)) }
            else { currentFrame = (tick / 8) % 2 == 0 ? "idleA" : "idleB" }
        }
        if !queue.isEmpty { dequeue() }
    }

    private func dequeue() {
        queue[0].ticks -= 1
        currentFrame = queue[0].frame
        if queue[0].ticks <= 0 { queue.removeFirst() }
    }
}
