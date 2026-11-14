import CoreGraphics
import Foundation

// MARK: - Intensity

/// Darkroom strength, from 0 (normal display) to 1 (red-only display).
///
/// The slider in the GUI and the CLI both speak in whole percent, so the
/// normalized value is quantized to 1/100 to make a stored intensity round-trip
/// exactly (`0.35` stays `0.35`, not `0.34999999999999998`).
public enum DarkroomIntensity {
    public static let minimum: Double = 0
    public static let maximum: Double = 1
    public static let defaultValue: Double = 1

    /// Clamp and quantize to whole percent.
    public static func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        let clamped = Swift.min(Swift.max(value, minimum), maximum)
        return (clamped * 100).rounded() / 100
    }

    public static func percent(from value: Double) -> Int {
        Int((normalized(value) * 100).rounded())
    }

    /// Parse user input: `"40"` and `"40%"` are percentages, `"0.4"` is a
    /// fraction. A bare integer is always a percentage, so `"1"` means 1% and
    /// not 100% — the fraction form is only recognised when the text carries a
    /// decimal point or exponent.
    public static func parse(_ text: String) -> Double? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasSuffix("%") {
            trimmed.removeLast()
            trimmed = trimmed.trimmingCharacters(in: .whitespaces)
        }
        guard !trimmed.isEmpty, let value = Double(trimmed), value.isFinite else {
            return nil
        }

        let isFraction = trimmed.contains(".") || trimmed.contains("e")
        let percent = isFraction ? value * 100 : value
        guard percent >= 0, percent <= 100 else { return nil }
        return normalized(percent / 100)
    }
}

public struct GammaTable: Sendable {
    public let capacity: Int
    public var red: [CGGammaValue]
    public var green: [CGGammaValue]
    public var blue: [CGGammaValue]

    public init(capacity: Int) {
        self.capacity = capacity
        self.red = [CGGammaValue](repeating: 0, count: capacity)
        self.green = [CGGammaValue](repeating: 0, count: capacity)
        self.blue = [CGGammaValue](repeating: 0, count: capacity)
    }

    /// Red-only ramp: full red, green and blue zeroed. Equivalent to
    /// `setIntensity(1)`.
    public mutating func setDarkroom() {
        setIntensity(1)
    }

    /// Identity ramp: every channel passes the input through unchanged.
    /// Equivalent to `setIntensity(0)`.
    public mutating func setIdentity() {
        setIntensity(0)
    }

    /// Red-only ramp scaled by `intensity` (0...1).
    ///
    /// Intensity `1` is the classic darkroom ramp (green/blue fully off), `0`
    /// is the identity ramp. In between, green and blue are faded out linearly
    /// while red keeps its full ramp, so brightness stays stable and only the
    /// color saturation changes. Values outside `0...1` are clamped.
    public mutating func setIntensity(_ intensity: Double) {
        guard capacity > 1 else { return }

        let level = CGGammaValue(DarkroomIntensity.normalized(intensity))
        let others = 1 - level
        let maxIndex = capacity - 1
        for i in 0..<capacity {
            let input = CGGammaValue(i) / CGGammaValue(maxIndex)
            red[i] = input
            green[i] = input * others
            blue[i] = input * others
        }
    }
}

/// Attenuation applied to the green and blue channels for a given intensity,
/// i.e. the factor that `setIntensity` uses. Kept separate (and pure) so the UI
/// and tests can reason about strength without touching gamma hardware.
public func channelAttenuation(forIntensity intensity: Double) -> Double {
    1 - DarkroomIntensity.normalized(intensity)
}

private struct GammaTableKey: Hashable {
    let capacity: Int
    let intensity: Double
}

private final class GammaTableBuffers {
    let table: GammaTable

    init(capacity: Int, intensity: Double) {
        var table = GammaTable(capacity: capacity)
        table.setIntensity(intensity)
        self.table = table
    }
}

/// Applies gamma tables while reusing the immutable buffers for each
/// (capacity, intensity) pair. Calls are serialized because CoreGraphics and
/// the cached buffers may be reached by both daemon commands and the reapply
/// timer.
public final class GammaApplier: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [GammaTableKey: GammaTableBuffers] = [:]

    public init() {}

    /// Apply `intensity` to the given displays. Intensity `0` restores the
    /// normal (identity) gamma table.
    ///
    /// Returns true when at least one display accepted the gamma table.
    ///
    /// CoreGraphics can include mirrored, virtual, and system-managed displays
    /// in the active display list even though they do not expose a writable
    /// gamma table. Those displays must not prevent capable displays from
    /// being updated.
    @discardableResult
    public func apply(intensity rawIntensity: Double, to displayIDs: [CGDirectDisplayID]) -> Bool {
        let intensity = DarkroomIntensity.normalized(rawIntensity)

        lock.lock()
        defer { lock.unlock() }

        guard !displayIDs.isEmpty else { return false }

        var appliedToAnyDisplay = false
        for id in displayIDs {
            let capacity = gammaTableCapacity(for: id)
            guard capacity > 1 else {
                continue
            }

            let key = GammaTableKey(capacity: capacity, intensity: intensity)
            let buffers: GammaTableBuffers
            if let cached = cache[key] {
                buffers = cached
            } else {
                // Keep the cache bounded: the slider produces at most 101
                // distinct intensities, and stale ones are cheap to rebuild.
                if cache.count > 512 {
                    cache.removeAll(keepingCapacity: true)
                }
                let newBuffers = GammaTableBuffers(capacity: capacity, intensity: intensity)
                cache[key] = newBuffers
                buffers = newBuffers
            }

            let result = buffers.table.red.withUnsafeBufferPointer { red in
                buffers.table.green.withUnsafeBufferPointer { green in
                    buffers.table.blue.withUnsafeBufferPointer { blue in
                        CGSetDisplayTransferByTable(
                            id,
                            UInt32(capacity),
                            red.baseAddress,
                            green.baseAddress,
                            blue.baseAddress
                        )
                    }
                }
            }
            if result == .success {
                appliedToAnyDisplay = true
            }
        }

        return appliedToAnyDisplay
    }

}

private let sharedGammaApplier = GammaApplier()

@discardableResult
public func applyGamma(intensity: Double, to displayIDs: [CGDirectDisplayID]) -> Bool {
    sharedGammaApplier.apply(intensity: intensity, to: displayIDs)
}

/// Read back how red-only a display currently is, as an intensity in `0...1`.
///
/// The gamma table does not record what we wrote, so this is measured from the
/// table itself: the green/blue attenuation at mid-scale is the intensity. A
/// display without a readable table reports `0`.
public func readDarkroomIntensity(for displayID: CGDirectDisplayID) -> Double {
    let capacity = gammaTableCapacity(for: displayID)
    guard capacity > 1 else { return 0 }

    var redTable = [CGGammaValue](repeating: 0, count: capacity)
    var greenTable = [CGGammaValue](repeating: 0, count: capacity)
    var blueTable = [CGGammaValue](repeating: 0, count: capacity)
    var sampleCount: UInt32 = 0

    let result = CGGetDisplayTransferByTable(
        displayID, UInt32(capacity),
        &redTable, &greenTable, &blueTable, &sampleCount
    )
    guard result == .success, sampleCount > 1 else { return 0 }

    let mid = Int(sampleCount) / 2
    let expected = CGGammaValue(mid) / CGGammaValue(Int(sampleCount) - 1)
    guard expected > 0.01 else { return 0 }

    // A display with no attenuation keeps every channel at the identity ramp.
    let attenuation = Swift.min(
        Double(greenTable[mid]) / Double(expected),
        Double(blueTable[mid]) / Double(expected)
    )
    return DarkroomIntensity.normalized(1 - Swift.max(0, Swift.min(1, attenuation)))
}

/// Measure the intensity currently active across the given displays.
///
/// Returns `0` when no display is tinted, otherwise the strongest tint found.
public func currentDarkroomIntensity(for displayIDs: [CGDirectDisplayID]) -> Double {
    displayIDs.reduce(0) { Swift.max($0, readDarkroomIntensity(for: $1)) }
}
