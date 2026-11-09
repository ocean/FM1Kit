import Testing

@_spi(Testing) @testable import FM1Kit

/// The range arithmetic behind ``FlashComparison``.
struct FlashComparisonRangeTests {
    @Test func findsTheRunsLeftUnclaimed() {
        #expect(FlashComparison.unclaimed(0..<100, [10..<20, 15..<30, 50..<60]) == [0..<10, 30..<50, 60..<100])
        #expect(FlashComparison.unclaimed(0..<10, [0..<10]).isEmpty)
    }

    @Test func joinsNeighbouringSectorsIntoOneRun() {
        let first = [UInt8](repeating: 0, count: 0x4000)
        var second = first
        second[0x1000] = 1
        second[0x2FFF] = 1
        #expect(FlashComparison.differingRuns(in: [0..<0x4000], first, second) == [0x1000..<0x3000])
        #expect(FlashComparison.differingRuns(in: [0x2000..<0x2800], first, second).isEmpty)
    }
}
