import Foundation
import AVFAudio

/// MicrophonePresenceSource (v14): the live half of sonic presence. Owns the
/// AVAudioEngine input tap and one SoundPresenceLayer, and translates its
/// events into `SpriteDirector.handleSound` calls — nothing else.
/// No audio is written, buffered beyond a single RMS sample, or retained.
///
/// Lifecycle (calm-technology discipline, the assessment's red lines):
/// - listens ONLY while the stage is visible and the session is active —
///   start()/stop() are idempotent and telemetry-light;
/// - never in the Always On rest state (the stage stops it on
///   luminance reduction and on leaving the active scene phase);
/// - one-time in-context permission ask, granted sessions record silence
///   on denial (the stage degrades with no error surface).
@MainActor
final class MicrophonePresenceSource {
    enum State: Equatable {
        case off            // not running
        case requesting     // permission sheet is up
        case listening
        var isListening: Bool { self == .listening }
    }

    private(set) var state: State = .off
    private var onStateChange: ((Bool) -> Void)?
    private var engine: AVAudioEngine?
    private var renderTimer: Timer?
    private var latestRMS: Float = 0
    private var hasFreshSample = false
    private let layer = SoundPresenceLayer()
    /// Consumed on the main actor; the AVAudioEngine tap hop is the only
    /// hop — the tap closure sets `pendingRMS` under the lock.
    private let sampleLock = NSLock()
    private var pendingRMS: Float = 0

    /// Points the source at the acting director (the stage re-binds it on
    /// companion switches).
    private(set) weak var director: SpriteDirector?

    init(onStateChange: (@MainActor (Bool) -> Void)? = nil) {
        self.onStateChange = onStateChange
    }

    func bind(director: SpriteDirector) {
        self.director = director
    }

    func start() {
        guard DirectorSettings.soundPresenceEnabled else { return }
        guard state == .off else { return }
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted:
            beginListening()
        case .undetermined:
            state = .requesting
            onStateChange?(false)
            session.requestRecordPermission { [weak self] granted in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.state == .requesting { self.state = .off }
                    if granted { self.start() }
                }
            }
        case .denied:
            state = .off
            onStateChange?(false)
        @unknown default:
            state = .off
        }
    }

    func stop() {
        renderTimer?.invalidate()
        renderTimer = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        let wasListening = state == .listening
        state = .off
        if wasListening { onStateChange?(false) }
    }

    private func beginListening() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true)
        } catch {
            // No record route / interrupted session: degrade silently.
            state = .off
            onStateChange?(false)
            return
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            state = .off
            return
        }
        // RMS per tap buffer; nothing else touches the samples. 512 frames
        // at 16-48 kHz is 10-32 ms — plenty for a 20 Hz loudness stream.
        input.installTap(onBus: 0, bufferSize: 512, format: format) { [weak self] buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            let frames = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<frames { sum += channel[i] * channel[i] }
            let rms = sqrtf(sum / Float(max(frames, 1)))
            guard let self else { return }
            self.sampleLock.lock()
            self.pendingRMS = rms
            self.hasFreshSample = true
            self.sampleLock.unlock()
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            state = .off
            onStateChange?(false)
            return
        }
        self.engine = engine
        state = .listening
        onStateChange?(true)
        let tickInterval = SoundPresenceLayer.tickDuration
        renderTimer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            self?.digest()
        }
    }

    private func digest() {
        guard state == .listening else { return }
        sampleLock.lock()
        let hasSample = hasFreshSample
        let sample = pendingRMS
        hasFreshSample = false
        sampleLock.unlock()
        // Normalized loudness: raw watch-mic RMS lands in the low
        // fractions; scaling brings speech to the ~0.1-0.3 band the
        // layer's thresholds are calibrated for. On-device tuning pass
        // owns the constant (see Tools/PIXEL_DESIGN.md §7).
        let level = hasSample ? min(1, sample * 6) : 0
        let events = layer.process(level: level)
        for event in events {
            director?.handleSound(event)
        }
    }
}

/// User-facing knobs for sonic presence (AppStorage-backed so the
/// Settings row and the source agree through a single source of truth).
enum DirectorSettings {
    static let soundPresenceKey = "listenForSounds"
    static var soundPresenceEnabled: Bool {
        UserDefaults.standard.object(forKey: soundPresenceKey) as? Bool ?? true
    }
}
