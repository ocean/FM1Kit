import Testing

@testable import FM1Kit

/// The README's and documentation's examples, run against the simulated FM-1 so they keep compiling.
struct DocExamplesTests {
    @Test func installingFirmwareExamplesRun() async throws {
        let package = try UpdaterTests.package()
        let device = SimulatedFM1(options: UpdaterTests.fastOptions)
        device.prepare(for: package)
        let updater = FM1Updater(transport: device, timing: UpdaterTests.fastTiming)

        let installed = try await updater.install(package) { event in
            switch event {
            case .staging(let requests): print("Preparing… \(requests)")
            case .writing(let fraction, _): print("Writing \(Int(fraction * 100))%")
            case .checking(let fraction, _): print("Checking \(Int(fraction * 100))%")
            case .finished(let identity): print("Now running \(identity)")
            default: break
            }
        }
        #expect(installed == package.identity)

        // A real FM-1 refuses the firmware it's running, so the README's example installs another.
        let other = try UpdaterTests.package(product: "FM-1_917")
        device.prepare(for: other)
        try await updater.install(other) { event in
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
