import Testing
@testable import DarkroomKit

@available(macOS 10.15, *)
@Test("GammaTable darkroom mode keeps red and zeros green and blue")
func darkroomTableValues() {
    let capacity = 1024
    var table = GammaTable(capacity: capacity)
    table.setDarkroom()

    let maxIndex = capacity - 1
    for index in 0..<capacity {
        let input = Float(index) / Float(maxIndex)
        #expect(abs(table.red[index] - input) < 0.001)
    }

    #expect(table.red.first == 0)
    #expect(table.red.last == 1)
    #expect(table.green.allSatisfy { $0 == 0 })
    #expect(table.blue.allSatisfy { $0 == 0 })
}

@available(macOS 10.15, *)
@Test("GammaTable identity mode makes all channels equal the input")
func identityTableValues() {
    let capacity = 1024
    var table = GammaTable(capacity: capacity)
    table.setIdentity()

    let maxIndex = capacity - 1
    for index in 0..<capacity {
        let expected = Float(index) / Float(maxIndex)
        #expect(abs(table.red[index] - expected) < 0.001)
        #expect(abs(table.green[index] - expected) < 0.001)
        #expect(abs(table.blue[index] - expected) < 0.001)
    }
}

@available(macOS 10.15, *)
@Test("GammaTable switches correctly between darkroom and identity")
func toggleTable() {
    let capacity = 1024
    var table = GammaTable(capacity: capacity)
    table.setDarkroom()
    table.setIdentity()

    let maxIndex = capacity - 1
    for index in 0..<capacity {
        let expected = Float(index) / Float(maxIndex)
        #expect(abs(table.red[index] - expected) < 0.001)
        #expect(abs(table.green[index] - expected) < 0.001)
        #expect(abs(table.blue[index] - expected) < 0.001)
    }
}

@available(macOS 10.15, *)
@Test("GammaTable handles the minimum usable capacity")
func minimumCapacity() {
    var table = GammaTable(capacity: 2)
    table.setDarkroom()

    #expect(table.red == [0, 1])
    #expect(table.green == [0, 0])
    #expect(table.blue == [0, 0])
}

@available(macOS 10.15, *)
@Test("GammaTable single-entry capacity does not produce NaN")
func singleEntryCapacity() {
    var table = GammaTable(capacity: 1)
    table.setDarkroom()
    #expect(table.red == [0])

    table.setIdentity()
    #expect(table.red == [0])
    #expect(table.green == [0])
    #expect(table.blue == [0])
}
