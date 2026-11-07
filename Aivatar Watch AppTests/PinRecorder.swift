import XCTest

/// PinRecorder (v26): one helper for the golden-pin tests. A pin table with
/// any zero entry is "unpinned" — the test fails with a RECORD MODE message
/// listing the freshly computed values to paste in, and never force-unwraps.
nonisolated enum PinRecorder {
    /// Fails (with the RECORD MODE message) when any pin is still zero.
    static func requirePinned<Key: Hashable>(
        _ expected: [Key: UInt64],
        recorded: String,
        label: String,
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        guard expected.values.allSatisfy({ $0 != 0 }) else {
            XCTFail("RECORD MODE — \(label) to pin: " + recorded, file: file, line: line)
            return
        }
    }

    /// Formats a recorded pin line without force-unwrapping.
    static func line<Key: RawRepresentable>(_ key: Key, _ actual: [Key: UInt64]) -> String
    where Key.RawValue == String {
        "\(key.rawValue) = \(actual[key] ?? 0)"
    }
}
