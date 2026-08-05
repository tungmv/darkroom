import CoreGraphics
import Foundation

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

    public mutating func setDarkroom() {
        guard capacity > 1 else { return }
        let maxIndex = capacity - 1
        for i in 0..<capacity {
            let input = CGGammaValue(i) / CGGammaValue(maxIndex)
            red[i] = input
            green[i] = 0.0
            blue[i] = 0.0
        }
    }

    public mutating func setIdentity() {
        guard capacity > 1 else { return }
        let maxIndex = capacity - 1
        for i in 0..<capacity {
            let input = CGGammaValue(i) / CGGammaValue(maxIndex)
            red[i] = input
            green[i] = input
            blue[i] = input
        }
    }
}

private struct GammaTableKey: Hashable {
    let capacity: Int
    let enabled: Bool
}

private final class GammaTableBuffers {
    var table: GammaTable

    init(capacity: Int, enabled: Bool) {
        var table = GammaTable(capacity: capacity)
        if enabled {
            table.setDarkroom()
        } else {
            table.setIdentity()
        }
        self.table = table
    }
}

/// Applies gamma tables while reusing the immutable buffers for each table
/// capacity. Calls are serialized because CoreGraphics and the cached buffers
/// may be reached by both daemon commands and the reapply timer.
public final class GammaApplier: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [GammaTableKey: GammaTableBuffers] = [:]

    public init() {}

    /// Returns true when at least one display accepted the gamma table.
    ///
    /// CoreGraphics can include mirrored, virtual, and system-managed displays
    /// in the active display list even though they do not expose a writable
    /// gamma table. Those displays must not prevent capable displays from
    /// being updated.
    @discardableResult
    public func apply(enabled: Bool, to displayIDs: [CGDirectDisplayID]) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !displayIDs.isEmpty else { return false }

        var appliedToAnyDisplay = false
        for id in displayIDs {
            let capacity = gammaTableCapacity(for: id)
            guard capacity > 1 else {
                continue
            }

            let key = GammaTableKey(capacity: capacity, enabled: enabled)
            let buffers: GammaTableBuffers
            if let cached = cache[key] {
                buffers = cached
            } else {
                let newBuffers = GammaTableBuffers(capacity: capacity, enabled: enabled)
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
public func applyGamma(enabled: Bool, to displayIDs: [CGDirectDisplayID]) -> Bool {
    sharedGammaApplier.apply(enabled: enabled, to: displayIDs)
}

public func readDarkroomActive(for displayID: CGDirectDisplayID) -> Bool {
    let capacity = gammaTableCapacity(for: displayID)
    guard capacity > 1 else { return false }

    var redTable = [CGGammaValue](repeating: 0, count: capacity)
    var greenTable = [CGGammaValue](repeating: 0, count: capacity)
    var blueTable = [CGGammaValue](repeating: 0, count: capacity)
    var sampleCount: UInt32 = 0

    let result = CGGetDisplayTransferByTable(
        displayID, UInt32(capacity),
        &redTable, &greenTable, &blueTable, &sampleCount
    )
    guard result == .success, sampleCount > 0 else { return false }

    let mid = Int(sampleCount) / 2
    return greenTable[mid] < 0.01 && blueTable[mid] < 0.01
}
