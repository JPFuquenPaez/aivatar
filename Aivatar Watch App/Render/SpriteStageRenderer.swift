import SwiftUI
import WatchKit

/// SpriteStageRenderer (v3 "Companion Cast"): the watch stage draws the
/// soft-toy vector puppet — the director's 150 ms grammar resolved into
/// pose targets, spring-interpolated at display rate with the continuous
/// ambient floor (breath, sway, flutter). The 40+ version-old pixel cell
/// raster and the AMS v2 cell-tail channel are retired with the character
/// itself; the director, its grammar, moods, bond/weather dials, farewell
/// beat and every golden stay.
///
/// Rest / Always On: a single static rest pose in the dimmed rest tokens —
/// no ticks, no subsecond updates (the v12 persistent-display rule, kept).
struct SpriteStageRenderer: View {
    let director: SpriteDirector
    /// CI/smoke hook (-stageAwake): the simulator dims to Always On on
    /// idle, which would screenshot the rest pose instead of the live
    /// stage. Never set in normal use.
    let forceAwake: Bool

    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    private var luminanceReduced: Bool { isLuminanceReduced && !forceAwake }
    @AppStorage("reduceMotionL2") private var reduceMotionL2 = false

    /// A5c farewell beat (U9): the goodbye plays at full color, then the
    /// stage hands over to the static rest pose — never a pop into the
    /// Always-On state (v12 persistent-display guidance).
    @State private var farewellPending = false
    @State private var farewellGeneration = 0
    @State private var farewellTotalSeconds: Double = 0
    @State private var farewellStartedAt: Date?
    @State private var greetedOnAppear = false

    var body: some View {
        ZStack {
            if luminanceReduced && !farewellPending {
                restPose
            } else {
                PuppetLiveStage(
                    driver: director,
                    ambientEnabled: !reduceMotionL2 && !WKAccessibilityIsReduceMotionEnabled()
                )
            }
            if farewellPending {
                // The dim ramp wipes in over the beat's last ticks (peak-end).
                TimelineView(.animation(minimumInterval: 0.15)) { timeline in
                    let bloom = Double(BondRules.farewellBloomTicks(director.bondLevel))
                        * SpriteDirector.tickDuration
                    let ramp: Double = {
                        guard let start = farewellStartedAt, farewellTotalSeconds > 0 else { return 0 }
                        return min(1, max(0, (timeline.date.timeIntervalSince(start)
                                              - (farewellTotalSeconds - bloom)) / bloom))
                    }()
                    Color.black.opacity(0.82 * ramp)
                }
                .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
        .onChange(of: luminanceReduced) { reduced in
            if reduced {
                beginFarewell()
            } else {
                farewellGeneration += 1
                farewellPending = false
                director.setResting(false)
                HapticsChannel.shared.wake()
                // v3: every wrist-raise starts with the companion noticing
                // you (§5.5 — the wake greeting moment).
                director.greet()
            }
        }
        .onAppear {
            // The cold-start visit is greeted too (an app launch is a wake).
            if !luminanceReduced, !greetedOnAppear {
                greetedOnAppear = true
                director.greet()
            }
        }
    }

    /// The static Always On rest pose: resolved once from a rest drive, in
    /// the dimmed rest tokens. Zero animation ticks.
    private var restPose: some View {
        var drive = PuppetDrive(archetype: director.currentArchetype, frameID: "sleepy")
        drive.resting = true
        let (pose, props) = PuppetPoser.resolve(drive)
        _ = props
        return PuppetPortraitView(
            archetype: director.currentArchetype,
            pose: pose,
            style: .rest,
            bondLevel: director.bondLevel
        )
        .id(director.currentArchetype)
    }

    /// U9 farewell beat on the director clock: idle, a blink, then the
    /// rest pose — with the dim ramp wiping in over the same beat.
    private func beginFarewell() {
        director.handleEvent(.sleep)
        farewellPending = true
        farewellGeneration += 1
        let generation = farewellGeneration
        farewellStartedAt = Date()
        farewellTotalSeconds = Double(3 + BondRules.farewellBloomTicks(director.bondLevel)) * SpriteDirector.tickDuration
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(farewellTotalSeconds * 1_000_000_000))
            guard generation == farewellGeneration else { return }
            farewellPending = false
            director.setResting(true)
        }
    }
}
