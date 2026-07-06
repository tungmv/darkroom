import Testing
@testable import DarkroomKit

@Test("GammaTable darkroom mode — red is inverted, green and blue are zero")
func darkroomTableValues() {
    let capacity = 1024
    var table = GammaTable(capacity: capacity)
    table.setDarkroom()

    let maxIndex = capacity - 1

    for i in 0..<capacity {
        let input = Float(i) / Float(maxIndex)
        #expect(abs(table.red[i] - (1.0 - input)) < 0.001)
    }

    #expect(table.green.allSatisfy { $0 == 0 })
    #expect(table.blue.allSatisfy { $0 == 0 })
}

@Test("GammaTable identity mode — all channels equal input")
func identityTableValues() {
    let capacity = 1024
    var table = GammaTable(capacity: capacity)
    table.setIdentity()

    let maxIndex = capacity - 1

    for i in 0..<capacity {
        let expected = Float(i) / Float(maxIndex)
        #expect(abs(table.red[i] - expected) < 0.001)
        #expect(abs(table.green[i] - expected) < 0.001)
        #expect(abs(table.blue[i] - expected) < 0.001)
    }
}

@Test("GammaTable switches correctly between darkroom and identity")
func toggleTable() {
    let capacity = 1024
    var table = GammaTable(capacity: capacity)
    table.setDarkroom()
    table.setIdentity()

    let maxIndex = capacity - 1
    for i in 0..<capacity {
        let expected = Float(i) / Float(maxIndex)
        #expect(abs(table.red[i] - expected) < 0.001)
        #expect(abs(table.green[i] - expected) < 0.001)
        #expect(abs(table.blue[i] - expected) < 0.001)
    }
}

@Test("GammaTable handles minimum capacity (2)")
func minimumCapacity() {
    var table = GammaTable(capacity: 2)
    table.setDarkroom()

    #expect(abs(table.red[0] - 1.0) < 0.001)
    #expect(abs(table.red[1] - 0.0) < 0.001)
    #expect(table.green[0] == 0)
    #expect(table.green[1] == 0)
    #expect(table.blue[0] == 0)
    #expect(table.blue[1] == 0)
}
