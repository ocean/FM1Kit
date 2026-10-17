import Testing

@testable import FM1Kit

/// End-to-end runs of the updater against the simulated FM-1, with timings shrunk.
struct UpdaterTests {
    static var fastTiming: UpdaterTiming {
        var timing = UpdaterTiming()
        timing.afterUpgradeCommand = .milliseconds(20)
        timing.finishSettle = .milliseconds(20)
        timing.stagingIdleLimit = .seconds(2)
        timing.loaderBoot = .milliseconds(20)
        timing.loaderSearch = .seconds(3)
        timing.writeIdleLimit = .seconds(2)
        timing.firmwareBoot = .milliseconds(20)
        timing.returnSearch = .seconds(3)
        timing.responseDelay = .zero
        timing.scanInterval = .milliseconds(30)
        timing.handshakeWait = .milliseconds(200)
        return timing
    }

    static var fastOptions: SimulatedFM1.Options {
        var options = SimulatedFM1.Options()
        options.stagingRequestCount = 5
        options.requestInterval = .zero
        options.rebootDuration = .milliseconds(100)
        options.responseTimeout = .seconds(1)
        return options
    }

    static func package(product: String = "FM-1_916") throws -> FwscPackage {
        try FwscPackage(bytes: FwscPackage.encode(product: product))
    }

    @Test func identifiesTheDevice() async {
        let updater = FM1Updater(transport: SimulatedFM1(options: Self.fastOptions), timing: Self.fastTiming)
        #expect(await updater.identify()?.text == "FM-1_900")
    }

    @Test func installsAndVerifiesTheIdentity() async throws {
        let device = SimulatedFM1(options: Self.fastOptions)
        let package = try Self.package()
        device.prepare(for: package)
        let updater = FM1Updater(transport: device, timing: Self.fastTiming)
        let installed = try await updater.install(package)
        #expect(installed.text == "FM-1_916")
        #expect(device.currentIdentity?.text == "FM-1_916")
    }

    @Test func resumesAfterTheCableIsPulledMidWrite() async throws {
        var options = Self.fastOptions
        options.unplugDuringWriteAt = 0.5
        let device = SimulatedFM1(options: options)
        let package = try Self.package()
        device.prepare(for: package)
        let updater = FM1Updater(transport: device, timing: Self.fastTiming)

        await #expect(throws: FM1UpdateError.self) { try await updater.install(package) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(device.currentIdentity?.isLoader == true)

        let installed = try await updater.resume(package)
        #expect(installed.text == "FM-1_916")
    }

    @Test func finishesFromUSBRecoveryMode() async throws {
        var options = Self.fastOptions
        options.startsInRecoveryMode = true
        let device = SimulatedFM1(options: options)
        let package = try Self.package()
        device.prepare(for: package)
        let updater = FM1Updater(transport: device, timing: Self.fastTiming)

        await #expect(throws: FM1UpdateError.deviceNotFound) { try await updater.install(package) }
        #expect(try await updater.resume(package).text == "FM-1_916")
    }

    @Test func refusesARequestBeyondTheImage() async throws {
        // The device expects a bigger image than the host has, so it asks past the end.
        let package = try Self.package()
        let beyond = UInt32(package.logicalImage.count - 256)
        let transport = ScriptedTransport(
            identity: FinishTests.firmware,
            script: [FM1ReadRequest(address: beyond, length: 512).encoded()]
        )
        let updater = FM1Updater(transport: transport, timing: Self.fastTiming)

        await #expect(throws: FM1UpdateError.badRequest(address: beyond, length: 512)) {
            try await updater.install(package)
        }
    }
}
