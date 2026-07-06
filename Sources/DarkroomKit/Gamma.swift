import CoreGraphics

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
        let maxIndex = capacity - 1
        for i in 0..<capacity {
            let input = CGGammaValue(i) / CGGammaValue(maxIndex)
            red[i] = 1.0 - input
            green[i] = 0.0
            blue[i] = 0.0
        }
    }

    public mutating func setIdentity() {
        let maxIndex = capacity - 1
        for i in 0..<capacity {
            let input = CGGammaValue(i) / CGGammaValue(maxIndex)
            red[i] = input
            green[i] = input
            blue[i] = input
        }
    }
}

@discardableResult
public func applyGamma(enabled: Bool, to displayIDs: [CGDirectDisplayID]) -> Bool {
    var allOK = true

    for id in displayIDs {
        let capacity = gammaTableCapacity(for: id)
        guard capacity > 0 else {
            allOK = false
            continue
        }

        var table = GammaTable(capacity: capacity)
        if enabled {
            table.setDarkroom()
        } else {
            table.setIdentity()
        }

        let result = CGSetDisplayTransferByTable(
            id, UInt32(capacity),
            &table.red, &table.green, &table.blue
        )
        if result != .success {
            allOK = false
        }
    }

    return allOK
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