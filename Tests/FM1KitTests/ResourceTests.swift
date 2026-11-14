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
        timing.resourceIdleLimit = .seconds(1)
        return timing
    }

    static func device(_ change: (inout SimulatedFM1.Options) -> Void = { _ in }) throws -> SimulatedFM1 {
        var options = UpdaterTests.fastOptions
        options.buildResources = try ResourceRegion(bytes: region)
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
