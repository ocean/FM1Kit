@testable import FM1Kit
import Testing

/// The README's and documentation's examples, run against the simulated FM-1 so they keep compiling.
struct DocExamplesTests {
    @Test func installingFirmwareExamplesRun() async throws {
        let package = try UpdaterTests.package()
        let device = SimulatedFM1(options: UpdaterTests.fastOptions)
        device.prepare(for: package)
        let updater = FM1Updater(transport: device, timing: UpdaterTests.fastTiming)

        let installed = try await updater.install(package) { event in
            switch event {
            case .staging(let requests): print("Checking… \(requests)")
            case .writing(let fraction, _): print("Writing \(Int(fraction * 100))%")
            case .finished(let identity): print("Now running \(identity)")
            default: break
            }
        }
        #expect(installed == package.identity)

        try await updater.install(package) { event in
            if case .writing(let fraction, _) = event {
                print("Writing \(Int(fraction * 100))%")
            }
        }

        if let identity = await updater.identify(), identity.isLoader {
            try await updater.resume(package)
        }
        #expect(OfficialFirmware.matching(package) == nil)
    }
}
