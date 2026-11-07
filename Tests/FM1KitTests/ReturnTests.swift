import Testing
import os

@_spi(Testing) @testable import FM1Kit

/// An install counts as done when the FM-1 comes back running the package, even if its loader
/// never asked to finish.
struct ReturnTests {
    /// What an install reported, and how long it took.
    struct Outcome {
        let installed: FM1Identity
        let events: [UpdateEvent]
        let took: Duration
    }

    static func install(_ change: (inout SimulatedFM1.Options) -> Void) async throws -> Outcome {
        var options = UpdaterTests.fastOptions
        change(&options)
        let device = SimulatedFM1(options: options)
        let package = try UpdaterTests.package()
        device.prepare(for: package)
        var timing = UpdaterTests.fastTiming
        timing.returnCheckAfter = .milliseconds(200)
        let updater = FM1Updater(transport: device, timing: timing)
        let events = OSAllocatedUnfairLock<[UpdateEvent]>(initialState: [])
        let start = ContinuousClock.now
        let installed = try await updater.install(package, options: .confirmed) { event in
            events.withLock { $0.append(event) }
        }
        return Outcome(installed: installed, events: events.withLock { $0 }, took: ContinuousClock.now - start)
    }

    @Test func finishesWhenTheFirmwareAnswersOnAConnectionThatNeverShowsAsLost() async throws {
        let result = try await Self.install { options in
            options.restartsWithoutFinishing = true
            options.keepsConnectionThroughRestart = true
        }
        #expect(result.installed.text == "FM-1_916")
        #expect(result.events.suffix(2) == [.rebooting, .finished(result.installed)])
        // Well before the loader would count as stalled.
        #expect(result.took < UpdaterTests.fastTiming.writeIdleLimit)
    }

    @Test func finishesWhenTheDeviceRestartsWithoutAskingToFinish() async throws {
        let result = try await Self.install { $0.restartsWithoutFinishing = true }
        #expect(result.installed.text == "FM-1_916")
        #expect(result.events.last == .finished(result.installed))
    }

    @Test func aCableCutNearTheEndStopsWhenTheLoaderComesBack() async throws {
        // The loader came back, not the firmware, so the write is left to resume.
        await #expect {
            try await Self.install { $0.unplugDuringWriteAt = 0.97 }
        } throws: { error in
            guard case FM1UpdateError.disconnected(.writing, _) = error else { return false }
            return true
        }
    }

    @Test func countsNearlyAllOfTheApplicationAreaAsNearlyWritten() {
        var progress = WriteProgress(region: 0..<1000)
        _ = progress.record(FM1ReadRequest(address: 0, length: 512))
        #expect(!progress.isNearlyWritten)
        _ = progress.record(FM1ReadRequest(address: 512, length: 450))
        #expect(progress.isNearlyWritten)
    }

    @Test func aSecondPassCountsOnlyOnceItIsNearlyDone() {
        // Felucca's loader checks the package in its first pass and writes in its second.
        var progress = WriteProgress(region: 0..<4096)
        for address in stride(from: 0, to: 4096, by: 512) {
            _ = progress.record(FM1ReadRequest(address: UInt32(address), length: 512))
        }
        #expect(progress.isNearlyWritten)
        for address in stride(from: 0, to: 2048, by: 512) {
            _ = progress.record(FM1ReadRequest(address: UInt32(address), length: 512))
        }
        #expect(!progress.isNearlyWritten)
        for address in stride(from: 2048, to: 4096, by: 512) {
            _ = progress.record(FM1ReadRequest(address: UInt32(address), length: 512))
        }
        #expect(progress.isNearlyWritten)
    }
}
