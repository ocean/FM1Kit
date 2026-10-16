import Testing
import os

@testable import FM1Kit

/// Write progress for the read orders seen from real loaders, on a 64-block image.
struct WriteProgressTests {
    static let block = 512
    static let imageLength = 64 * block

    /// Feeds reads of whole blocks to a fresh tracker and returns the events.
    static func events(forBlocks blocks: [Int], imageLength: Int = imageLength) -> [UpdateEvent] {
        var progress = WriteProgress(imageLength: imageLength)
        return blocks.map { progress.record(FM1ReadRequest(address: UInt32($0 * block), length: block)) }
    }

    static func writingFractions(_ events: [UpdateEvent]) -> [Double] {
        events.compactMap { if case .writing(let fraction, _) = $0 { fraction } else { nil } }
    }

    static func checkingFractions(_ events: [UpdateEvent]) -> [Double] {
        events.compactMap { if case .checking(let fraction, _) = $0 { fraction } else { nil } }
    }

    @Test func aForwardsPassRisesSteadilyToTheEnd() {
        let fractions = Self.writingFractions(Self.events(forBlocks: Array(0..<64)))
        #expect(fractions.count == 64)
        #expect(fractions == fractions.sorted())
        #expect(fractions.first == 1.0 / 64)
        #expect(fractions.last == 1)
    }

    @Test func aBackwardsPassRisesSteadilyRatherThanJumping() {
        // V15's loader reads from the end backwards; the furthest offset would show 100% at once.
        let fractions = Self.writingFractions(Self.events(forBlocks: Array((0..<64).reversed())))
        #expect(fractions.first == 1.0 / 64)
        #expect(fractions == fractions.sorted())
        #expect(fractions.last == 1)
    }

    @Test func headerRereadsAtTheStartAreStillWriting() {
        // Loaders re-read the first blocks as they start, long before most of the image is read.
        let blocks = [0, 1, 2, 2, 1, 0] + Array((3..<64).reversed())
        let events = Self.events(forBlocks: blocks)
        #expect(Self.checkingFractions(events).isEmpty)
        #expect(Self.writingFractions(events).last == 1)
    }

    @Test func shortRereadsAtTheEndAreStillWriting() {
        // V15's loader ends with a few reads of 10 to 16 bytes from the header.
        var progress = WriteProgress(imageLength: Self.imageLength)
        for block in (0..<64).reversed() {
            _ = progress.record(FM1ReadRequest(address: UInt32(block * Self.block), length: Self.block))
        }
        #expect(progress.record(FM1ReadRequest(address: 0x100, length: 10)) == .writing(fraction: 1, requests: 65))
        #expect(progress.record(FM1ReadRequest(address: 0x93, length: 16)) == .writing(fraction: 1, requests: 66))
    }

    @Test func aSecondPassIsReportedAsChecking() {
        // Felucca's loader reads the image forwards, then reads it again.
        let events = Self.events(forBlocks: Array(0..<64) + Array(0..<64))
        let writing = Self.writingFractions(events)
        let checking = Self.checkingFractions(events)
        #expect(writing.last == 1)
        // The first re-reads count as writing until there are enough in a row to be a pass.
        let rereads = WriteProgress.rereadsBeforeChecking
        #expect(writing.count == 64 + rereads - 1)
        #expect(checking.count == 64 - rereads + 1)
        #expect(checking == checking.sorted())
        #expect(checking.last == 1)
        #expect(events[64 + rereads - 1] == .checking(fraction: Double(rereads) / 64, requests: rereads))
    }

    @Test func aRereadAtTheEndOfAPassIsStillWriting() {
        // V15's loader reads block 34 (0x4400) while starting, and again as its backwards pass ends.
        let events = Self.events(forBlocks: [0, 1, 34] + Array((2..<64).reversed()))
        #expect(Self.checkingFractions(events).isEmpty)
        #expect(Self.writingFractions(events).last == 1)
    }

    @Test func newGroundDuringCheckingGoesBackToWriting() {
        let blocks = Array(0..<40) + [0, 1, 2, 3] + Array(40..<64)
        let events = Self.events(forBlocks: blocks)
        #expect(Self.checkingFractions(events).count == 2)
        #expect(events.last == .writing(fraction: 1, requests: 24))
    }

    @Test func aLoaderThatSkipsPartOfTheImageEndsShortOfOne() {
        // V15's loader writes about 84% of its image; the rest is read only while staging.
        let fractions = Self.writingFractions(Self.events(forBlocks: Array(0..<54)))
        #expect(fractions.last == 54.0 / 64)
    }

    @Test func aShortFinalReadIsCounted() {
        var progress = WriteProgress(imageLength: 1000)
        _ = progress.record(FM1ReadRequest(address: 0, length: 512))
        #expect(progress.record(FM1ReadRequest(address: 512, length: 488)) == .writing(fraction: 1, requests: 2))
    }
}

/// The updater's progress events against simulated loaders that read like the real ones.
struct LoaderReadOrderTests {
    /// Installs with these simulator options and returns every event.
    static func installEvents(_ configure: (inout SimulatedFM1.Options) -> Void) async throws -> [UpdateEvent] {
        var options = UpdaterTests.fastOptions
        configure(&options)
        let device = SimulatedFM1(options: options)
        let package = try UpdaterTests.package()
        device.prepare(for: package)
        let events = OSAllocatedUnfairLock(initialState: [UpdateEvent]())
        try await FM1Updater(transport: device, timing: UpdaterTests.fastTiming).install(package) { event in
            events.withLock { $0.append(event) }
        }
        return events.withLock { $0 }
    }

    @Test func aBackwardsLoaderReportsSteadyProgress() async throws {
        let events = try await Self.installEvents { $0.writesBackwards = true }
        let fractions = WriteProgressTests.writingFractions(events)
        #expect(fractions.first ?? 1 < 0.1)
        #expect(fractions == fractions.sorted())
        #expect(fractions.last == 1)
        #expect(WriteProgressTests.checkingFractions(events).isEmpty)
    }

    @Test func aCheckingLoaderReportsCheckingAfterWriting() async throws {
        let events = try await Self.installEvents { $0.checksAfterWriting = true }
        #expect(WriteProgressTests.writingFractions(events).last == 1)
        let checking = WriteProgressTests.checkingFractions(events)
        #expect(!checking.isEmpty)
        #expect(checking == checking.sorted())
        #expect(checking.last == 1)
        let lastWriting = events.lastIndex { if case .writing = $0 { true } else { false } }
        let firstChecking = events.firstIndex { if case .checking = $0 { true } else { false } }
        #expect(lastWriting ?? 0 < firstChecking ?? 0)
    }
}
