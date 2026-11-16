import Testing
import os

@_spi(Testing) @testable import FM1Kit

/// Firmwares' resource regions: reading them, finding them in packages, and writing them over
/// USB-MIDI to the simulated FM-1.
struct ResourceTests {
    static let region = ResourceRegion.sampleBytes(payloadLength: 5_000)

    static func package(resources: FwscPackage.SamplePart, bytes: [UInt8] = region) throws -> FwscPackage {
        let image = FwscPackage.sampleImage(parts: [.flash(), .loader(), resources], contents: [2: bytes])
        return try FwscPackage(bytes: FwscPackage.sampleFile(logicalImage: image, product: "FM-1_916"))
    }

    static var fastTiming: UpdaterTiming {
        var timing = UpdaterTests.fastTiming
        timing.resourceStartWait = .milliseconds(500)
        timing.resourceSectorEraseWait = .milliseconds(10)
        timing.resourceIdleLimit = .seconds(1)
        return timing
    }

    static func device(_ change: (inout SimulatedFM1.Options) -> Void = { _ in }) throws -> SimulatedFM1 {
        var options = UpdaterTests.fastOptions
        options.buildResources = try ResourceRegion(bytes: region)
        options.resourceSectorErase = .zero
        change(&options)
        return SimulatedFM1(options: options)
    }

    @Test func readsARegion() throws {
        let resources = try ResourceRegion(bytes: Self.region)
        #expect(resources.payloadLength == 5_000)
        #expect(resources.payload.count == 5_000)
        #expect(resources.address == nil)
        #expect(resources.flashRange == nil)
        #expect(ResourceRegion.hasHeader(Self.region))
    }

    @Test func refusesWhatIsNotARegion() {
        var damaged = Self.region
        damaged[ResourceRegion.headerLength + 100] ^= 1
        #expect(throws: ResourceRegion.Failure.damaged) { try ResourceRegion(bytes: damaged) }
        var header = Self.region
        header[12] ^= 1
        #expect(throws: ResourceRegion.Failure.notResources) { try ResourceRegion(bytes: header) }
        #expect(throws: ResourceRegion.Failure.damaged) {
            try ResourceRegion(bytes: Array(Self.region.prefix(ResourceRegion.headerLength + 10)))
        }
        #expect(throws: ResourceRegion.Failure.tooShort) { try ResourceRegion(bytes: [0x52, 0x45]) }
    }

    @Test func findsFM1BaseResourcesInAPackage() throws {
        let package = try Self.package(resources: .resources(size: Self.region.count, at: 0x9_7000))
        #expect(package.resources?.address == 0x9_7000)
        #expect(package.resources?.flashRange == 0x9_7000..<0x9_9000)
        #expect(package.resources?.payloadLength == 5_000)
        #expect(!package.carriesOtherResources)
    }

    @Test func leavesOtherResourcesToTheLoader() throws {
        // Melodee's part names no address, and holds its own header.
        let melodee = try Self.package(
            resources: .resources(size: 8_192, at: 0),
            bytes: [UInt8](repeating: 0x4D, count: 8_192)
        )
        #expect(melodee.resources == nil)
        #expect(melodee.carriesOtherResources)
        for address in [0x9_7800, 0x9_6000, 0xD_F000, 0x4000] {
            let package = try Self.package(resources: .resources(size: Self.region.count, at: address))
            #expect(package.resources == nil, "at 0x\(String(address, radix: 16))")
        }
        #expect(try UpdaterTests.package().carriesOtherResources == false)
    }

    @Test func writesResourcesOverUSBMIDI() async throws {
        let device = try Self.device()
        let updater = FM1Updater(transport: device, timing: Self.fastTiming)
        let resources = try ResourceRegion(bytes: Self.region)
        let last = OSAllocatedUnfairLock(initialState: 0.0)
        try await updater.writeResources(resources) { value in last.withLock { $0 = value } }
        #expect(device.currentResources == Array(resources.payload))
        #expect(last.withLock { $0 } == 1)
    }

    @Test func answersAtOnceWhenTheResourcesAreThere() async throws {
        let device = try Self.device()
        let updater = FM1Updater(transport: device, timing: Self.fastTiming)
        let resources = try ResourceRegion(bytes: Self.region)
        try await updater.writeResources(resources)
        let values = OSAllocatedUnfairLock(initialState: [Double]())
        try await updater.writeResources(resources) { value in values.withLock { $0.append(value) } }
        // No reads in between: the firmware has nothing to fetch.
        #expect(values.withLock { $0 } == [0, 1])
        #expect(device.currentResources == Array(resources.payload))
    }

    @Test func waitsWhileTheFirmwareErases() async throws {
        // Two sectors at 1.25 s each outlast the 1 s start wait, but not the second a sector it adds.
        let device = try Self.device { $0.resourceSectorErase = .milliseconds(1_250) }
        var timing = Self.fastTiming
        timing.resourceStartWait = .seconds(1)
        timing.resourceSectorEraseWait = .seconds(1)
        let updater = FM1Updater(transport: device, timing: timing)
        try await updater.writeResources(try ResourceRegion(bytes: Self.region))
        #expect(device.currentResources != nil)
    }

    @Test func waitsWhileTheFirmwareAsks() async throws {
        // The answer takes longer than the 1 s idle limit.
        let device = try Self.device { $0.resourceAskPause = .milliseconds(2_500) }
        var timing = Self.fastTiming
        timing.resourceAskWait = .seconds(5)
        let updater = FM1Updater(transport: device, timing: timing)
        try await updater.writeResources(try ResourceRegion(bytes: Self.region))
        #expect(device.currentResources != nil)
    }

    @Test func refusesAReadLongerThanAllowed() async throws {
        let device = try Self.device { $0.resourceReadLength = 600 }
        let updater = FM1Updater(transport: device, timing: Self.fastTiming)
        await #expect(throws: FM1UpdateError.resourcesBadRequest(address: 0, length: 600)) {
            try await updater.writeResources(try ResourceRegion(bytes: Self.region))
        }
        #expect(!FM1UpdateError.resourcesBadRequest(address: 0, length: 600).advice.isDeviceFine)
    }

    @Test func reportsAnotherBuildsResources() async throws {
        let device = try Self.device()
        let updater = FM1Updater(transport: device, timing: Self.fastTiming)
        let other = try ResourceRegion(bytes: ResourceRegion.sampleBytes(payloadLength: 5_000, seed: 3))
        await #expect(throws: FM1UpdateError.resourcesRefused(code: 20)) { try await updater.writeResources(other) }
        #expect(device.currentResources == nil)
    }

    @Test func reportsARefusal() async throws {
        let device = try Self.device { $0.resourceRefusal = 10 }
        let updater = FM1Updater(transport: device, timing: Self.fastTiming)
        await #expect(throws: FM1UpdateError.resourcesRefused(code: 10)) {
            try await updater.writeResources(try ResourceRegion(bytes: Self.region))
        }
        #expect(FM1UpdateError.resourcesRefused(code: 10).advice.isDeviceFine)
    }

    @Test func saysWhenTheFirmwareDoesNotTakeResources() async throws {
        let device = try Self.device { $0.buildResources = nil }
        let updater = FM1Updater(transport: device, timing: Self.fastTiming)
        await #expect(throws: FM1UpdateError.resourcesNotTaken(device: "FM-1_900")) {
            try await updater.writeResources(try ResourceRegion(bytes: Self.region))
        }
    }
}

/// Installing a package that carries its resources over USB-MIDI, after which the new firmware is
/// asked for them in case its loader left them out.
struct ResourceInstallTests {
    /// Installs a package carrying fm1-base resources on a simulated FM-1 and returns its events.
    static func install(on device: SimulatedFM1) async throws -> (FwscPackage, [UpdateEvent]) {
        let package = try ResourceTests.package(resources: .resources(size: ResourceTests.region.count, at: 0x9_7000))
        device.prepare(for: package)
        let events = OSAllocatedUnfairLock(initialState: [UpdateEvent]())
        let updater = FM1Updater(transport: device, timing: ResourceTests.fastTiming)
        let installed = try await updater.install(package, options: .confirmed) { event in
            events.withLock { $0.append(event) }
        }
        #expect(installed.text == "FM-1_916")
        return (package, events.withLock { $0 })
    }

    static func device(_ change: (inout SimulatedFM1.Options) -> Void = { _ in }) -> SimulatedFM1 {
        var options = UpdaterTests.fastOptions
        options.resourceSectorErase = .zero
        change(&options)
        return SimulatedFM1(options: options)
    }

    @Test func theFirmwareAnswersAtOnceWhenTheLoaderWroteThem() async throws {
        let device = Self.device()
        let (package, events) = try await Self.install(on: device)
        #expect(device.currentResources == package.resources.map { Array($0.payload) })
        let rebooting = try #require(events.firstIndex(of: .rebooting))
        #expect(!events[rebooting...].contains { if case .writingResources = $0 { true } else { false } })
        #expect(!events.contains { if case .resourcesNotWritten = $0 { true } else { false } })
        #expect(device.events.contains("The resources are there already."))
    }

    @Test func theFirmwareWritesThemWhenTheLoaderLeftThemOut() async throws {
        let device = Self.device { $0.loaderLeavesResources = true }
        let (package, events) = try await Self.install(on: device)
        #expect(device.currentResources == package.resources.map { Array($0.payload) })
        let rebooting = try #require(events.firstIndex(of: .rebooting))
        let fractions = events[rebooting...].compactMap { event -> Double? in
            if case .writingResources(let fraction, _) = event { fraction } else { nil }
        }
        #expect(fractions.last == 1)
        #expect(fractions == fractions.sorted())
        #expect(!events[..<rebooting].contains { if case .writingResources = $0 { true } else { false } })
        #expect(events.last == .finished(FM1Identity(model: "FM-1", version: 916)))
    }

    @Test func aRefusalIsReportedWithoutFailingTheInstall() async throws {
        let device = Self.device { options in
            options.loaderLeavesResources = true
            options.resourceRefusal = 21
        }
        let (_, events) = try await Self.install(on: device)
        #expect(device.currentResources == nil)
        #expect(events.contains(.resourcesNotWritten(.resourcesRefused(code: 21))))
        #expect(events.last == .finished(FM1Identity(model: "FM-1", version: 916)))
    }

    @Test func aPackageWithoutResourcesAsksForNone() async throws {
        let device = Self.device()
        let package = try UpdaterTests.package()
        device.prepare(for: package)
        try await FM1Updater(transport: device, timing: ResourceTests.fastTiming).install(package, options: .confirmed)
        #expect(!device.events.contains { $0.contains("resource") })
    }
}
