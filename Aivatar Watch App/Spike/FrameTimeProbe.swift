import Foundation
import os

nonisolated let spikeLogger = Logger(subsystem: "com.aivatar.spike", category: "probe")

/// A0 frame-time measurement harness.
///
/// Records per-frame CPU work (engine update + display-list dispatch) and the
/// achieved frame interval while the spike renders, then prints a summary line
/// prefixed `AIVATAR-SPIKE:` for capture via `simctl launch --console`.
///
/// Used from single-threaded render loops only (SwiftUI Canvas closure and the
/// SpriteKit scene update, both main-thread); no cross-thread use, so the class
/// is deliberately not actor-isolated to match SpriteKit's nonisolated API.
nonisolated final class FrameTimeProbe {
    let renderer: String
    let capacity: Int

    private var cpuSamples: [Double]
    private var intervalSamples: [Double]
    private var index = 0
    private var lastTimestamp: Double = 0
    private let startedAt: Double

    init(renderer: String, capacity: Int) {
        self.renderer = renderer
        self.capacity = capacity
        cpuSamples = [Double](repeating: 0, count: capacity)
        intervalSamples = [Double](repeating: 0, count: capacity)
        startedAt = CFAbsoluteTimeGetCurrent()
    }

    /// `cpu` = seconds of CPU work this frame; `timestamp` = wall time of frame.
    func record(cpu: Double, timestamp: Double) {
        guard index < capacity else { return }
        cpuSamples[index] = cpu
        if index > 0 {
            intervalSamples[index] = max(0, timestamp - lastTimestamp)
        } else {
            intervalSamples[index] = 0
        }
        lastTimestamp = timestamp
        index += 1

        if index % 150 == 0 {
            printSummary(final: false)
        }
        if index == capacity {
            printSummary(final: true)
        }
    }

    private func stats(_ samples: [Double], count: Int) -> (mean: Double, p50: Double, p95: Double, max: Double) {
        // Discard the first 30 frames as warmup.
        guard count > 32 else { return (0, 0, 0, 0) }
        var sorted: [Double] = []
        sorted.reserveCapacity(count - 30)
        var total: Double = 0
        for i in 30..<count {
            sorted.append(samples[i])
            total += samples[i]
        }
        sorted.sort()
        let n = sorted.count
        let mean: Double = total / Double(n)
        let p50: Double = sorted[(n - 1) / 2]
        let p95: Double = sorted[min(n - 1, Int(Double(n - 1) * 0.95))]
        return (mean, p50, p95, sorted[n - 1])
    }

    private func printSummary(final: Bool) {
        let cpu = stats(cpuSamples, count: index)
        let interval = stats(intervalSamples, count: index)
        let tag = final ? "RESULT" : "PROGRESS"
        let cpuMean = cpu.mean * 1000
        let cpuP50 = cpu.p50 * 1000
        let cpuP95 = cpu.p95 * 1000
        let cpuMax = cpu.max * 1000
        let intMean = interval.mean * 1000
        let intP95 = interval.p95 * 1000
        let intMax = interval.max * 1000
        let wall = CFAbsoluteTimeGetCurrent() - startedAt
        let line = String(
            format: "AIVATAR-SPIKE: %@ renderer=%@ frames=%d cpu_ms mean=%.2f p50=%.2f p95=%.2f max=%.2f interval_ms mean=%.2f p95=%.2f max=%.2f wall_s=%.1f",
            tag, renderer, index,
            cpuMean, cpuP50, cpuP95, cpuMax,
            intMean, intP95, intMax, wall
        )
        print(line)
        spikeLogger.log("\(line, privacy: .public)")
    }
}
