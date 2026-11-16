import Foundation
import SwiftUI

/// PuppetLiveDriver (v3): the seam between a motion brain and the renderer.
/// The watch's SpriteDirector and the iPhone shell's PhoneCompanionAnimator
/// both conform: given a director-clock tick, they advance deterministically
/// and return the flattened puppet drive state. The brain stays in charge of
/// its clock and story; the renderer only paints.
nonisolated protocol PuppetLiveDriver: AnyObject {
    /// Advances to `tick` (idempotent) and returns the drive snapshot.
    nonisolated func puppetDrive(atTick tick: Int) -> PuppetDrive
    /// The discrete scheduling clock (seconds per tick).
    nonisolated var puppetTickDuration: Double { get }
    /// The companion being driven (spec source).
    nonisolated var puppetArchetype: Archetype { get }
    /// True while the stage should render the static rest pose.
    nonisolated var puppetIsResting: Bool { get }
}

/// The spring bank + timing, as a class so the Canvas draw closure (driven
/// by TimelineView) can step it without touching view state.
nonisolated final class PuppetSolverController: @unchecked Sendable {
    var bank = PuppetSpringBank()
    var now: Double = 0
    var lastAt: Double?
    var startedAt: Double = 0

    /// One pure display step: resolve the target pose, spring toward it,
    /// fold in the ambient layer. Same inputs → same pose, always.
    func step(drive: PuppetDrive, ambient: Bool) -> (pose: PuppetPose, props: PuppetProps) {
        if lastAt == nil { startedAt = now; lastAt = now - 1.0 / 30.0 }
        let dt = max(0, min(1.0 / 20.0, now - (lastAt ?? now)))
        lastAt = now
        let (target, props) = PuppetPoser.resolve(drive)
        var pose = bank.interpolate(target: target, dt: dt)
        let full = ambient && drive.motionFloor == .full && !drive.resting
        PuppetAmbient.apply(to: &pose, at: now - startedAt, full: full)
        return (pose, props)
    }

    /// Cold-start reset (companion switch): springs land settled at neutral.
    func reset() {
        bank = PuppetSpringBank()
        lastAt = nil
    }
}

/// PuppetLiveStage (v3): the shared live renderer — the director's discrete
/// grammar resolved into pose targets, spring-interpolated at display rate
/// with the continuous ambient floor (breathing, sway, flutter), drawn once
/// through the Canvas backend. One view is both the watch stage's canvas and
/// the iPhone companion: the same animal, the same motion truth.
nonisolated struct PuppetLiveStage<Driver: PuppetLiveDriver>: View {
    let driver: Driver
    var ambientEnabled: Bool = true
    var style: PuppetStyle = .flat

    @State private var solver = PuppetSolverController()
    @State private var epoch = Date()

    nonisolated var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { ctx, size in
                solver.now = timeline.date.timeIntervalSince(epoch)
                let tick = Int((solver.now / driver.puppetTickDuration).rounded(.down))
                let drive = driver.puppetDrive(atTick: tick)
                let (pose, props) = solver.step(drive: drive,
                                                ambient: ambientEnabled && !driver.puppetIsResting)
                // v1.1 three-zone layout: the art is confined to the stage
                // zone (18%..74% height) — it never reaches the dock captions.
                let spec = CompanionToys.spec(for: driver.puppetArchetype)
                let layout = PuppetDrawing.Layout.fitZoned(canvas: size, spec: spec)
                PuppetDrawing.draw(
                    PuppetDrawing.CanvasSurface(
                        ctx: ctx, device: layout.deviceTransform),
                    spec: spec, pose: pose, props: props,
                    style: driver.puppetIsResting ? .rest : style,
                    time: solver.now,
                    growthScale: CompanionToys.growthScale(bondLevel: drive.bondLevel),
                    accessory: CompanionToys.accessory(bondLevel: drive.bondLevel),
                    hueShift: drive.hueShiftDeg)
            }
        }
        .onDisappear { solver.reset() }
    }
}

/// A static (non-ticking) puppet portrait — the setup heroes, postcard
/// fronts and previews: one resolved pose, no springs, no timeline.
nonisolated struct PuppetPortraitView: View {
    let archetype: Archetype
    var pose: PuppetPose = PuppetPose()
    var props: PuppetProps = PuppetProps()
    var style: PuppetStyle = .flat
    var bondLevel: Int = 1
    var time: Double = 0

    nonisolated var body: some View {
        Canvas { ctx, size in
            let layout = PuppetDrawing.Layout.fit(canvas: size, scaleFactor: 0.94)
            PuppetDrawing.draw(
                PuppetDrawing.CanvasSurface(ctx: ctx, device: layout.deviceTransform),
                spec: CompanionToys.spec(for: archetype),
                pose: pose, props: props, style: style, time: time,
                growthScale: CompanionToys.growthScale(bondLevel: bondLevel),
                accessory: CompanionToys.accessory(bondLevel: bondLevel))
        }
    }
}
