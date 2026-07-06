import CoreGraphics

public struct DisplayInfo: Sendable {
    public let id: CGDirectDisplayID
    public let name: String

    public init(id: CGDirectDisplayID, name: String) {
        self.id = id
        self.name = name
    }
}

public func getActiveDisplays() -> [DisplayInfo] {
    var displayCount: UInt32 = 0
    let maxDisplays: UInt32 = 32
    var displays = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))

    guard CGGetActiveDisplayList(maxDisplays, &displays, &displayCount) == .success,
          displayCount > 0
    else {
        return []
    }

    return (0..<Int(displayCount)).map { i in
        let id = displays[i]
        return DisplayInfo(id: id, name: displayName(for: id))
    }
}

public func gammaTableCapacity(for display: CGDirectDisplayID) -> Int {
    Int(CGDisplayGammaTableCapacity(display))
}

private func displayName(for display: CGDirectDisplayID) -> String {
    if let mode = CGDisplayCopyDisplayMode(display) {
        let builtin = CGDisplayIsBuiltin(display) != 0
        let label = builtin ? "Built-in" : "External"
        return "\(label) \(mode.pixelWidth)x\(mode.pixelHeight)"
    }
    if CGDisplayIsBuiltin(display) != 0 {
        return "Built-in Display"
    }
    return "Display \(display)"
}
