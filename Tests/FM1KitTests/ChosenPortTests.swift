import Testing

@_spi(Testing) @testable import FM1Kit

/// A simulated FM-1 whose firmware renames its USB port, as some do.
final class RenamedPortTransport: MIDITransport, Sendable {
    let device: SimulatedFM1
    let name: String
    let usbProductName: String?

    init(_ device: SimulatedFM1, name: String, usbProductName: String? = nil) {
        self.device = device
        self.name = name
        self.usbProductName = usbProductName
    }

    func ports() async -> [MIDIPortDescriptor] {
        await device.ports().map { port in
            MIDIPortDescriptor(id: port.id, name: name, serialNumber: port.serialNumber, usbProductName: usbProductName)
        }
    }

    func open(_ port: MIDIPortDescriptor) async throws -> any MIDIConnection {
        try await device.open(MIDIPortDescriptor(id: port.id, name: SimulatedFM1.portName))
    }

    func changes() -> AsyncStream<Void> { AsyncStream { _ in } }
}

/// The ports a person chooses to probe, for firmwares that rename their USB port.
struct ChosenPortTests {
    @Test func leavesARenamedPortAloneUnlessChosen() async {
        let device = SimulatedFM1(options: UpdaterTests.fastOptions)
        let transport = RenamedPortTransport(device, name: "Pocket Synth")
        #expect(await FM1Updater(transport: transport, timing: UpdaterTests.fastTiming).devices().isEmpty)
        #expect(device.events.isEmpty)

        let updater = FM1Updater(transport: transport, timing: UpdaterTests.fastTiming, alsoProbing: ["pocket synth"])
        #expect(await updater.devices().map(\.identity.text) == ["FM-1_900"])
    }

    @Test func matchesTheUSBProductNameExactlyIgnoringCase() async {
        let transport = SilentTransport(ports: [])
        let updater = FM1Updater(transport: transport, alsoProbing: ["Pocket Synth"])
        #expect(updater.probes(MIDIPortDescriptor(id: "a", name: "Old Name", usbProductName: "POCKET SYNTH")))
        #expect(updater.probes(MIDIPortDescriptor(id: "b", name: "FM-1 Midi")))
        #expect(!updater.probes(MIDIPortDescriptor(id: "c", name: "Pocket Synth 2")))
        #expect(!updater.probes(MIDIPortDescriptor(id: "d", name: "Arturia KeyStep 37")))
    }

    @Test func installsThroughARenamedPort() async throws {
        let device = SimulatedFM1(options: UpdaterTests.fastOptions)
        let package = try UpdaterTests.package()
        device.prepare(for: package)
        let updater = FM1Updater(
            transport: RenamedPortTransport(device, name: "Pocket Synth"),
            timing: UpdaterTests.fastTiming,
            alsoProbing: ["Pocket Synth"]
        )
        let installed = try await updater.install(package, options: .confirmed)
        #expect(installed.text == package.product)
    }
}
