import Foundation
import Testing
@testable import DarkroomKit

// MARK: - Intensity ramp

@available(macOS 10.15, *)
@Test("Intensity 0 is the identity ramp")
func intensityZeroIsIdentity() {
    let capacity = 1024
    var table = GammaTable(capacity: capacity)
    table.setIntensity(0)

    let maxIndex = capacity - 1
    for index in 0..<capacity {
        let expected = Float(index) / Float(maxIndex)
        #expect(abs(table.red[index] - expected) < 0.001)
        #expect(abs(table.green[index] - expected) < 0.001)
        #expect(abs(table.blue[index] - expected) < 0.001)
    }
}

@available(macOS 10.15, *)
@Test("Intensity 1 matches the classic darkroom ramp")
func intensityOneMatchesDarkroom() {
    let capacity = 1024
    var scaled = GammaTable(capacity: capacity)
    scaled.setIntensity(1)

    var classic = GammaTable(capacity: capacity)
    classic.setDarkroom()

    #expect(scaled.red == classic.red)
    #expect(scaled.green == classic.green)
    #expect(scaled.blue == classic.blue)
}

@available(macOS 10.15, *)
@Test("Red is untouched and green/blue fade linearly with intensity")
func intensityFadesOnlyGreenAndBlue() {
    let capacity = 256
    let maxIndex = capacity - 1

    for percent in stride(from: 0, through: 100, by: 5) {
        var table = GammaTable(capacity: capacity)
        let intensity = Double(percent) / 100
        table.setIntensity(intensity)

        let attenuation = Float(channelAttenuation(forIntensity: intensity))
        for index in 0..<capacity {
            let input = Float(index) / Float(maxIndex)
            #expect(abs(table.red[index] - input) < 0.001)
            #expect(abs(table.green[index] - input * attenuation) < 0.001)
            #expect(abs(table.blue[index] - input * attenuation) < 0.001)
        }
    }
}

@available(macOS 10.15, *)
@Test("Out-of-range intensities are clamped, not arbitrary")
func intensityClamping() {
    var table = GammaTable(capacity: 8)
    table.setIntensity(-5)
    var identity = GammaTable(capacity: 8)
    identity.setIdentity()
    #expect(table.green == identity.green)
    #expect(table.blue == identity.blue)

    table.setIntensity(42)
    var full = GammaTable(capacity: 8)
    full.setDarkroom()
    #expect(table.green == full.green)
    #expect(table.blue == full.blue)
}

@available(macOS 10.15, *)
@Test("Single-entry capacity stays degenerate rather than NaN")
func intensitySingleEntry() {
    var table = GammaTable(capacity: 1)
    table.setIntensity(0.5)
    #expect(table.red == [0])
    #expect(table.green == [0])
    #expect(table.blue == [0])
}

// MARK: - Normalization

@Test("Intensity normalizes to whole percent")
func intensityNormalization() {
    #expect(DarkroomIntensity.normalized(0.3549) == 0.35)
    #expect(DarkroomIntensity.normalized(0.3551) == 0.36)
    #expect(DarkroomIntensity.normalized(-3) == 0)
    #expect(DarkroomIntensity.normalized(3) == 1)
    #expect(DarkroomIntensity.normalized(.nan) == DarkroomIntensity.defaultValue)
    #expect(DarkroomIntensity.normalized(.infinity) == DarkroomIntensity.defaultValue)
}

@Test("Intensity percent conversion round-trips")
func intensityPercentRoundTrip() {
    for percent in 0...100 {
        let intensity = DarkroomIntensity.normalized(Double(percent) / 100)
        #expect(DarkroomIntensity.percent(from: intensity) == percent)
    }
}

@Test("Channel attenuation is the complement of intensity")
func attenuationComplementsIntensity() {
    #expect(channelAttenuation(forIntensity: 0) == 1)
    #expect(channelAttenuation(forIntensity: 1) == 0)
    #expect(abs(channelAttenuation(forIntensity: 0.25) - 0.75) < 0.0001)
}

// MARK: - Wire protocol

@Test("Commands serialize to the documented wire format")
func commandWireValues() {
    #expect(DarkroomCommand.on.wireValue == "on")
    #expect(DarkroomCommand.off.wireValue == "off")
    #expect(DarkroomCommand.status.wireValue == "status")
    #expect(DarkroomCommand.stop.wireValue == "stop")
    #expect(DarkroomCommand.get.wireValue == "get")
    #expect(DarkroomCommand.intensity(0.35).wireValue == "intensity 35")
    #expect(DarkroomCommand.intensity(1).wireValue == "intensity 100")
    #expect(DarkroomCommand.intensity(0).wireValue == "intensity 0")
}

@Test("Wire commands parse back, including percentages and fractions")
func commandParsing() {
    #expect(DarkroomCommand(wireValue: "on") == .on)
    #expect(DarkroomCommand(wireValue: "off") == .off)
    #expect(DarkroomCommand(wireValue: "status") == .status)
    #expect(DarkroomCommand(wireValue: "stop") == .stop)
    #expect(DarkroomCommand(wireValue: "get") == .get)
    #expect(DarkroomCommand(wireValue: "intensity 35") == .intensity(0.35))
    #expect(DarkroomCommand(wireValue: "intensity 35%") == .intensity(0.35))
    #expect(DarkroomCommand(wireValue: "intensity 0.35") == .intensity(0.35))
    #expect(DarkroomCommand(wireValue: "intensity 100") == .intensity(1))
    #expect(DarkroomCommand(wireValue: "intensity 0") == .intensity(0))
}

@Test("Malformed or unknown commands are rejected")
func commandRejectsInvalidInput() {
    #expect(DarkroomCommand(wireValue: "") == nil)
    #expect(DarkroomCommand(wireValue: "bogus") == nil)
    #expect(DarkroomCommand(wireValue: "intensity") == nil)
    #expect(DarkroomCommand(wireValue: "intensity abc") == nil)
    #expect(DarkroomCommand(wireValue: "intensity -5") == nil)
    #expect(DarkroomCommand(wireValue: "intensity 101") == nil)
}

@Test("Daemon intensity responses parse")
func intensityResponseParsing() {
    #expect(DarkroomClient.parseIntensityResponse("intensity 35") == 0.35)
    #expect(DarkroomClient.parseIntensityResponse("intensity ok 35") == 0.35)
    #expect(DarkroomClient.parseIntensityResponse("intensity 0") == 0)
    #expect(DarkroomClient.parseIntensityResponse("intensity 100") == 1)
    #expect(DarkroomClient.parseIntensityResponse("on") == nil)
    #expect(DarkroomClient.parseIntensityResponse("intensity") == nil)
    #expect(DarkroomClient.parseIntensityResponse("intensity abc") == nil)
}

@Test("User input parses as percent, fraction, or percent sign")
func intensityInputParsing() {
    #expect(DarkroomIntensity.parse("40") == 0.4)
    #expect(DarkroomIntensity.parse("40%") == 0.4)
    #expect(DarkroomIntensity.parse("0.4") == 0.4)
    #expect(DarkroomIntensity.parse("0") == 0)
    #expect(DarkroomIntensity.parse("100") == 1)
    // A bare 1 is one percent, not a fraction.
    #expect(DarkroomIntensity.parse("1") == 0.01)
    #expect(DarkroomIntensity.parse(" 60 ") == 0.6)
    #expect(DarkroomIntensity.parse("1.0") == 1)
    #expect(DarkroomIntensity.parse("-1") == nil)
    #expect(DarkroomIntensity.parse("101") == nil)
    #expect(DarkroomIntensity.parse("abc") == nil)
    #expect(DarkroomIntensity.parse("") == nil)
}
