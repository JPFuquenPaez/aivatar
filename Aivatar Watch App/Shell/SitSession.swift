import Foundation
import Combine

/// SitSession (Aivatar 2.0, E8): the shell-side coordinator for the mindful
/// minute. Owns the session lifecycle around the director's session grammar:
/// start (cap check + in-context Health write ask on first use + marker
/// haptics), end (log >= 200 ticks to memory + one mindfulSession sample,
/// once per session), and the stage captions ("Breathe with %@" first cycle,
/// alternating breathe-in/out under Reduce Motion L2, "%@ sat with you" at
/// the end). Entry points: the Settings row and the workout page's long-press
/// hero — never the stage page (its long-press belongs to the slow-blink
/// ritual: one gesture, one meaning).
@MainActor
final class SitSession: ObservableObject {
    static let shared = SitSession()

    /// True while a breath session runs on the live director.
    @Published private(set) var active = false
    /// Transient stage caption (first-cycle hint / L2 in-out / done line).
    @Published var caption: String? = nil

    private var startDate: Date?
    private var endMarkerTask: Task<Void, Never>?

    private init() {}

    private var director: SpriteDirector? { AvatarSession.shared.spriteDirector }
    private var archetype: Archetype { AvatarSession.shared.archetype }
    private var stageName: String {
        let name = UserDefaults.standard.string(forKey: "companionName") ?? ""
        return name.isEmpty ? archetype.displayName : name
    }

    /// Starts a session if the daily cap allows (cap 3/day, never stated).
    func start() {
        guard !active, let director else { return }
        let store = CompanionMemoryStore()
        let memory = store.load()
        guard BreathSessionController.canLogToday(
            sitCountDay: memory?.sitCountDay, lastSitDay: memory?.lastSitDay, now: Date()) else { return }
        active = true
        startDate = Date()
        caption = String(format: String(localized: "sit.session.hint"), stageName)
        director.onSessionEnded = { [weak self] elapsed in
            Task { @MainActor in await self?.handleEnd(elapsedTicks: elapsed) }
        }
        director.setSessionMode(true)
        // Marker haptics: tick 0 .click now; tick 396 .success via timer.
        HapticsChannel.shared.sessionMarker(start: true)
        let endMarkerSec = Double(BreathSessionController.endMarkerTick) * SpriteDirector.tickDuration
        endMarkerTask?.cancel()
        endMarkerTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(endMarkerSec * 1_000_000_000))
            if active { HapticsChannel.shared.sessionMarker(start: false) }
        }
        // First-use in-context write ask (denial -> dormant flag, no re-prompt).
        if memory?.mindfulWriteDenied != true {
            Task {
                let granted = await MindfulnessBridge().requestWriteAccessIfNeeded()
                if !granted {
                    var m = CompanionMemoryStore().load() ?? CompanionMemory()
                    m.mindfulWriteDenied = true
                    CompanionMemoryStore().save(m)
                }
            }
        }
    }

    /// Ends the session early (called when a tap/crown ends it — the director
    /// already flipped sessionMode; this just mirrors the UI state). The
    /// director's onSessionEnded does the real logging.
    private func handleEnd(elapsedTicks: Int) async {
        active = false
        endMarkerTask?.cancel()
        // First-cycle hint fades; the done line shows ~5 s.
        caption = String(format: String(localized: "sit.session.done"), stageName)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if caption != nil { caption = nil }
        }
        guard BreathSessionController.shouldLog(elapsedTicks: elapsedTicks),
              let start = startDate else { return }
        startDate = nil
        let end = Date()
        // Cap accounting (content-free): count the logged session today.
        let store = CompanionMemoryStore()
        var memory = store.load() ?? CompanionMemory()
        let day = CompanionMemoryStore.dayIndex(of: end)
        if memory.lastSitDay == day {
            memory.sitCountDay = (memory.sitCountDay ?? 0) + 1
        } else {
            memory.lastSitDay = day
            memory.sitCountDay = 1
        }
        store.save(memory)
        // The one Health write — only when not denied.
        if memory.mindfulWriteDenied != true {
            try? await MindfulnessBridge().saveSession(start: start, end: end)
        }
    }

    /// The L2 caption for the current session phase ("Breathe in" during the
    /// 27-tick inhale, "Breathe out" during the 53-tick exhale).
    func phaseCaption() -> String {
        guard active, let director else { return "" }
        let elapsed = director.sessionElapsedTicks
        return (elapsed % BreathSessionController.cycleTicks) < BreathSessionController.inhaleTicks
            ? String(localized: "sit.session.breatheIn")
            : String(localized: "sit.session.breatheOut")
    }

    /// Whether the first-cycle hint is still showing (elapsed < one cycle).
    var firstCycle: Bool {
        guard active, let director else { return false }
        return director.sessionElapsedTicks < BreathSessionController.cycleTicks
    }
}
