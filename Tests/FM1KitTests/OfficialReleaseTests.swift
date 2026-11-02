import Testing

@_spi(Testing) @testable import FM1Kit

/// M-VAVE's official releases: V15, which apps may include, and V16, which they download.
struct OfficialReleaseTests {
    @Test func onlyV15MayBeIncludedInAnApp() {
        #expect(OfficialFirmware.official == [.v15, .v16])
        #expect(OfficialFirmware.known.filter(\.isRedistributable) == [.v15])
        #expect(OfficialFirmware.official.map(\.identity.text) == ["FM-1_015", "FM-1_016"])
        #expect(OfficialFirmware.official.map(\.identity.isOfficial) == [true, true])
        let openIdentity = OfficialFirmware.openV12.identity
        #expect(!openIdentity.isOfficial)
    }

    @Test func v16IsTreatedAsTheOfficialFirmwareToo() async throws {
        var options = UpdaterTests.fastOptions
        options.installedIdentity = .officialV16
        let device = SimulatedFM1(options: options)
        let package = try UpdaterTests.package(product: "FM-1_016")
        device.prepare(for: package)
        let updater = FM1Updater(transport: device, timing: UpdaterTests.fastTiming)
        let check = try await updater.check(package)
        #expect(check.kind == .reinstall)
        #expect(check.canReinstallOfficial)
        await #expect(throws: FM1UpdateError.alreadyInstalled("FM-1_016")) {
            try await updater.install(package, options: .confirmed)
        }
        #expect(FM1UpdateError.alreadyInstalled("FM-1_016").advice.action == .confirm)
    }
}
