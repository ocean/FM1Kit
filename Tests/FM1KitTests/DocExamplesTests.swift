import Testing
import os

@_spi(Testing) @testable import FM1Kit

/// The README's and documentation's examples, run against the simulated FM-1 so they keep compiling.
struct DocExamplesTests {
    @Test func checkingExampleRuns() async throws {
        let package = try UpdaterTests.package()
        let updater = FM1Updater(
            transport: SimulatedFM1(options: UpdaterTests.fastOptions), timing: UpdaterTests.fastTiming)

        let check = try await updater.check(package)
        switch check.kind {
        case .update: print("A new build of the open firmware \(check.device) is running")
        case .switchingFirmware: print("Switching from \(check.device): back up projects and samples first")
        case .reinstall: print("\(check.device) is already installed")
        case .sameIdentity: print("\(check.device) is running: reinstall it, or update to another release?")
        }
        #expect(check.kind == .switchingFirmware)
    }

    @Test func installingFirmwareExamplesRun() async throws {
        let package = try UpdaterTests.package()
        let device = SimulatedFM1(options: UpdaterTests.fastOptions)
        device.prepare(for: package)
        let updater = FM1Updater(transport: device, timing: UpdaterTests.fastTiming)

        let options = InstallOptions(confirmsSwitchingFirmware: true)
        let installed = try await updater.install(package, options: options) { event in
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
        try await updater.install(other, options: options) { event in
            switch event {
            case .staging(let requests): print("Preparing… \(requests)")
            case .writing(let fraction, _): print("Writing \(Int(fraction * 100))%")
            case .checking(let fraction, _): print("Checking \(Int(fraction * 100))%")
            case .finished(let identity): print("Now running \(identity)")
            default: break
            }
        }

        if let identity = await updater.identify(), identity.isLoader {
            try await updater.resume(package)
        }
        #expect(OfficialFirmware.matching(package) == nil)
    }

    @Test func progressAndAdviceExampleRuns() async throws {
        let package = try UpdaterTests.package()
        let device = SimulatedFM1(options: UpdaterTests.fastOptions)
        let updater = FM1Updater(transport: device, timing: UpdaterTests.fastTiming)
        let options = InstallOptions(confirmsSwitchingFirmware: true)
        let progress = OSAllocatedUnfairLock(initialState: InstallProgress())

        // The device isn't told to expect the package, so it stops answering while staging.
        do {
            try await updater.install(package, options: options) { event in
                progress.withLock { $0.record(event) }
            }
            Issue.record("The install should have stopped.")
        } catch {
            let advice = FM1Advice(for: error)
            #expect(advice.action == .tryAgain)
            #expect(advice.isDeviceFine)
        }
        #expect(progress.withLock { $0.stage } == .gettingReady)
    }

    @Test func summaryExampleRuns() async throws {
        let updater = FM1Updater(
            transport: SimulatedFM1(options: UpdaterTests.fastOptions), timing: UpdaterTests.fastTiming)
        if let summary = try await updater.summary() {
            print(summary.firmwareName ?? summary.identity.text)
            if summary.isWaitingMidUpdate { print("Offer to finish the update") }
            print(summary.serialNumber ?? "no serial number")
            #expect(summary.serialNumber == "SIMULATED-FM-1")
        } else {
            Issue.record("The simulated FM-1 should answer.")
        }
    }

    @Test func bootloaderExampleRuns() async throws {
        var options = UpdaterTests.fastOptions
        options.installedIdentity = .officialV15
        let device = SimulatedFM1(options: options)
        let installer = try BootloaderInstaller(package: FwscPackage(data: FwscPackage.sampleBootloaderInstallerFile()))
        device.prepare(for: installer.package)
        let updater = FM1Updater(transport: device, timing: UpdaterTests.fastTiming)
        print(installer.bootloader.version)
        try await updater.installBootloader(installer)
        #expect(device.installedBootloaderVersion == installer.bootloader.version)
    }
}
