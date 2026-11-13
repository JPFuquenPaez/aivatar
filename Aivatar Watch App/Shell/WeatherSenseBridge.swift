import Foundation
import CoreLocation
#if canImport(WeatherKit)
import WeatherKit
#endif

/// WeatherSenseBridge (F3): WeatherKit current conditions, fetched ON
/// VISIT/WAKE ONLY with a 60-min cache — never a background poll (G9; the
/// free tier is 500k calls/month, ample at this cadence). All classification
/// is on-device; the engine sees only the class hash. WeatherKit is
/// watchOS 11+ — on watchOS 10 the feature is dormant (poll returns []).
/// Location is the device's own one-shot fix (WhenInUse, in-context ask);
/// any failure -> .unknown -> no event.
nonisolated final class WeatherSenseBridge: LifeSenseSource, @unchecked Sendable {
    private let memoryStore: CompanionMemoryStore
    private let lock = NSLock()
    private var cachedClass: ConditionClass?
    private var cachedAt: Date?
    private var refreshRequested = false

    /// Cache lifetime — one fetch per hour max.
    static let cacheSec: TimeInterval = 3_600

    init(memoryStore: CompanionMemoryStore = CompanionMemoryStore()) {
        self.memoryStore = memoryStore
    }

    /// v25 (audit M2): ask for WhenInUse location AT THE TOGGLE FLIP (the
    /// opt-in moment), not on the next stage visit. Idempotent; the fetch
    /// itself still only happens on poll.
    nonisolated func requestLocationAuthorizationIfNeeded() {
        let manager = CLLocationManager()
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    /// Sync lock helper (NSLock is unavailable directly in async contexts).
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    // MARK: - Pure core (unit-tested without WeatherKit/location)

    /// Classify raw conditions into the closed set. Inputs are plain values
    /// so the whole table is testable: the WeatherKit adapter maps
    /// CurrentWeather into them (condition rawValue, °C, m/s).
    static func classify(conditionRaw: String, temperatureC: Double, windMS: Double) -> ConditionClass {
        let c = conditionRaw.lowercased()
        let rainy = c.contains("rain") || c.contains("drizzle") || c.contains("thunder")
            || c.contains("sleet") || c.contains("snow") || c.contains("hail")
        let snowy = c.contains("snow")
        let windy = c.contains("wind") || windMS >= 10
        let cloudy = c.contains("cloud") || c.contains("overcast") || c.contains("fog")
            || c.contains("haze") || c.contains("smoke")
        let clear = c.contains("clear") || c.contains("sunny")
        if rainy { return snowy && temperatureC <= 0 ? .cold : .rain }
        if temperatureC <= 2 { return .cold }
        if temperatureC >= 30 { return .hot }
        if windy { return .wind }
        if clear { return .sunny }
        if cloudy { return .gray }
        return .unknown
    }

    /// The day-stable emission rule: emit the class once per (class, day) —
    /// re-opens on the same gray day are one ambient note, not a loop.
    static func shouldEmit(classHash: Int, dayIndex: Int, log: [LifeLogEntry]) -> Bool {
        let kindHash = LifeKind.hash(of: .weatherClass)
        return !log.contains {
            $0.kindHash == kindHash && $0.dayIndex == dayIndex && $0.classHash == classHash
        }
    }

    // MARK: - LifeSenseSource

    /// Async poll (v23 protocol): returns the weather event when the cached
    /// class is known and not yet logged today. Kicks an async refresh when
    /// the cache is stale (fire-and-forget — poll itself never blocks on the
    /// network).
    nonisolated func poll(now: Date) async -> [LifeEvent] {
        let klass = withLock { cachedClass }
        refreshIfStale(now: now)
        guard let klass, klass != .unknown else { return [] }
        let dayIndex = CompanionMemoryStore.dayIndex(of: now)
        let log = memoryStore.load()?.lifeLog ?? []
        guard Self.shouldEmit(classHash: klass.hash, dayIndex: dayIndex, log: log) else { return [] }
        return [.weatherClass(classHash: klass.hash)]
    }

    /// True when the cache is older than the lifetime (or never fetched).
    private func refreshIfStale(now: Date) {
        lock.lock()
        let stale = cachedAt.map { now.timeIntervalSince($0) >= Self.cacheSec } ?? true
        if stale && !refreshRequested { refreshRequested = true }
        let shouldRefresh = stale && refreshRequested
        lock.unlock()
        guard shouldRefresh else { return }
        if #available(watchOS 11, *) {
            Task { [weak self] in
                await self?.refresh(now: now)
            }
        }
    }

    // MARK: - Fetch (watchOS 11+; dormant below)

    @available(watchOS 11, *)
    private func refresh(now: Date) async {
        defer { setRefreshRequested(false) }
        do {
            let location = try await Self.currentLocation()
            let weather = try await WeatherService.shared.weather(for: location)
            let current = weather.currentWeather
            let klass = Self.classify(
                conditionRaw: "\(current.condition)",
                temperatureC: current.temperature.converted(to: .celsius).value,
                windMS: current.wind.speed.converted(to: .metersPerSecond).value)
            setCache(klass, at: now)
        } catch {
            setCache(.unknown, at: now)
        }
    }

    // Sync lock helpers (NSLock is unavailable directly in async contexts).
    private func setCache(_ klass: ConditionClass, at date: Date) {
        lock.lock(); cachedClass = klass; cachedAt = date; lock.unlock()
    }

    private func setRefreshRequested(_ value: Bool) {
        lock.lock(); refreshRequested = value; lock.unlock()
    }

    /// One-shot device location via CLLocationManager (WhenInUse). Any failure
    /// throws -> .unknown -> neutral behavior, never a crash. The delegate is
    /// retained for the duration of the request (CLLocationManager.delegate is
    /// weak) and the continuation resumes exactly once (v23 fix: the old code
    /// could deallocate the delegate before any callback AND double-resume).
    @available(watchOS 11, *)
    private static func currentLocation() async throws -> CLLocation {
        let manager = CLLocationManager()
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        for _ in 0..<50 {
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways: break
            case .denied, .restricted: throw WeatherError.locationDenied
            default: break
            }
            if manager.authorizationStatus == .authorizedWhenInUse
                || manager.authorizationStatus == .authorizedAlways { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard manager.authorizationStatus == .authorizedWhenInUse
            || manager.authorizationStatus == .authorizedAlways else {
            throw WeatherError.locationDenied
        }
        let delegate = OneShotDelegate()
        manager.delegate = delegate  // weak on the manager; the closures below retain it
        return try await withCheckedThrowingContinuation { cont in
            delegate.setHandler { result in
                switch result {
                case .success(let loc): cont.resume(returning: loc)
                case .failure(let err): cont.resume(throwing: err)
                }
            }
            manager.requestLocation()
            Task { [weak delegate] in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                delegate?.emitTimeout()
            }
        }
    }

    private enum WeatherError: Error { case locationDenied, timeout }

    /// Resume-once delegate: the first result (location, error, or timeout)
    /// wins; later callbacks are dropped.
    @available(watchOS 11, *)
    private final class OneShotDelegate: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var handler: (@Sendable (Result<CLLocation, Error>) -> Void)?
        private var done = false

        func setHandler(_ h: @escaping @Sendable (Result<CLLocation, Error>) -> Void) {
            lock.lock(); handler = h; lock.unlock()
        }

        func emitTimeout() { emit(.failure(WeatherError.timeout)) }

        private func emit(_ result: Result<CLLocation, Error>) {
            lock.lock()
            guard !done else { lock.unlock(); return }
            done = true
            let h = handler
            lock.unlock()
            h?(result)
        }

        func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
            if let loc = locations.last { emit(.success(loc)) }
        }
        func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
            emit(.failure(error))
        }
    }
}
