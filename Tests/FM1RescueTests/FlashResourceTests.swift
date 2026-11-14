@_spi(Testing) import FM1Kit
import Foundation
import Testing

@testable import FM1Rescue

/// Installing a firmware whose package carries its resources, in download mode and with the
/// Transporter.
struct FlashResourceTests {
    static let region = ResourceRegion.sampleBytes(payloadLength: 5_000)
    static let address = 0x9_7000
    static let range = 0x9_7000..<0x9_9000

    /// A package of the sample flash's firmware, with a resources part going to `address`.
    static func package(address: Int = address, bytes: [UInt8] = region) throws -> FwscPackage {
        let flash = SampleFlash.flash(code: SampleFlash.code(fill: 0x77))
        let resources = FwscPackage.SamplePart.resources(size: bytes.count, at: address)
        let image = FwscPackage.sampleImage(
            parts: [.flash(size: 0x8000), .loader(), resources],
            contents: [0: Array(flash[0..<0x8000]), 2: bytes]
        )
        return try FwscPackage(data: Data(FwscPackage.sampleFile(logicalImage: image, product: "FM-1_378001")))
    }

    /// The sample flash, with `fill` where the resources go.
    static func flash(holding fill: [UInt8]) -> [UInt8] {
        var flash = SampleFlash.flash()
        flash.replaceSubrange(range, with: fill + repeatElement(0xFF, count: range.count - fill.count))
        return flash
    }

    @Test func writesResourcesIntoBlankFlash() throws {
        let chip = SimulatedDownloadMode(flash: Self.flash(holding: []))
        let (session, current) = try FlashWriteTests.read(chip)
        let plan = try FlashPlan.installing(try Self.package(), onto: current)
        #expect(plan.notes.contains("Writes its resources (0x97000–0x98FFF)."))
        #expect(plan.afterwards.isEmpty)
        try session.write(plan)
        #expect(Array(chip.flash[Self.range]) == Self.region + repeatElement(0xFF, count: 0x2000 - Self.region.count))

        // Installing the same package again leaves the resources as they are.
        let again = try FlashPlan.installing(try Self.package(), onto: try session.backUp())
        #expect(again.isEmpty)
    }

    @Test func replacesOlderResources() throws {
        let older = ResourceRegion.sampleBytes(payloadLength: 4_000, seed: 3)
        let current = SampleFlash.backup(Self.flash(holding: older))
        let plan = try FlashPlan.installing(try Self.package(), onto: current)
        #expect(Array(plan.target[Self.range].prefix(Self.region.count)) == Self.region)
        #expect(plan.sectors.contains(Self.address))
    }

    @Test func leavesResourcesOutOverOtherData() throws {
        // An older build's projects may still be there, waiting to move.
        let current = SampleFlash.backup(Self.flash(holding: [UInt8](repeating: 0x55, count: 0x100)))
        let plan = try FlashPlan.installing(try Self.package(), onto: current)
        #expect(!plan.sectors.contains { Self.range.contains($0) })
        #expect(plan.afterwards.count == 1)
        #expect(plan.afterwards.first?.contains("install it again over USB-MIDI") == true)
    }

    @Test func leavesResourcesOutOverDataPastSmallerOnes() throws {
        // An older build's smaller resources take one sector; its projects may follow them.
        var flash = Self.flash(holding: ResourceRegion.sampleBytes(payloadLength: 100, seed: 3))
        flash.replaceSubrange(0x9_8000..<0x9_8100, with: repeatElement(0x55, count: 0x100))
        let plan = try FlashPlan.installing(try Self.package(), onto: SampleFlash.backup(flash))
        #expect(!plan.sectors.contains { Self.range.contains($0) })
        #expect(plan.afterwards.count == 1)
    }

    @Test func writesResourcesAfterErasingSavedData() throws {
        let chip = SimulatedDownloadMode(flash: Self.flash(holding: [UInt8](repeating: 0x55, count: 0x100)))
        let (session, current) = try FlashWriteTests.read(chip)
        let plan = try FlashPlan.installing(try Self.package(), onto: current, erasingSavedData: true)
        try session.write(plan)
        #expect(Array(chip.flash[Self.range].prefix(Self.region.count)) == Self.region)
        #expect(chip.flash[Self.range.upperBound..<0xF_C000].allSatisfy { $0 == 0xFF })
        #expect(chip.flash[0x8000..<Self.address].allSatisfy { $0 == 0xFF })
    }

    @Test func leavesOtherResourcesToTheLoader() throws {
        // Melodee's part names no address.
        let package = try Self.package(address: 0, bytes: [UInt8](repeating: 0x4D, count: 0x2000))
        let current = SampleFlash.backup(Self.flash(holding: []))
        let plan = try FlashPlan.installing(package, onto: current, erasingSavedData: true)
        #expect(!plan.notes.contains { $0.contains("resources") })
        #expect(plan.afterwards.count == 1)
    }

    @Test func theTransporterLeavesResourcesForLater() throws {
        let dump = SampleFlash.backup(Self.flash(holding: []))
        let plan = try FlashPlan.installingWithTransporter(try Self.package(), onto: dump)
        #expect(plan.sectors.allSatisfy { FlashPlan.transporterWritable.contains($0) })
        #expect(plan.afterwards.contains { $0.contains("install it again over USB-MIDI") })
    }
}
