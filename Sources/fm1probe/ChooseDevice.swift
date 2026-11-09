import FM1Kit
import Foundation

/// Prints every device that answers, numbered for `--device`.
func listDevices() async throws {
    let transport = try CoreMIDITransport(clientName: "fm1probe")
    let devices = await FM1Updater(transport: transport, alsoProbing: await chosenPortNames(transport)).devices()
    if isJSON {
        printJSON(DevicesJSON(devices))
        if devices.isEmpty { fail() }
        return
    }
    if devices.isEmpty {
        print("No FM-1 answered. Check it's connected and switched on, then run `fm1probe ports`.")
        fail()
    }
    printDevices(devices)
}

/// An updater for the device to use: the only one that answers, or the one `--device` names.
///
/// Stops with the list of devices when more than one answers and `--device` doesn't name one of
/// them. With none answering, the updater is returned as it is, for the command to report that.
func chosenUpdater(_ transport: any MIDITransport) async -> FM1Updater {
    let portNames = await chosenPortNames(transport)
    let devices = await FM1Updater(transport: transport, alsoProbing: portNames).devices()
    let wanted = option("--device")
    guard devices.count > 1 || wanted != nil else { return FM1Updater(transport: transport, alsoProbing: portNames) }
    guard let wanted else {
        print("\(devices.count) devices answered. Choose one with --device N or --device SERIAL:")
        printDevices(devices)
        fail()
    }
    let matches = devices.enumerated().filter { index, device in
        String(index + 1) == wanted || device.serialNumber == wanted
    }
    guard matches.count == 1, let device = matches.first?.element else {
        print(
            matches.isEmpty
                ? "No device answered as \(wanted). These did:"
                : "More than one device answered as \(wanted). Choose one by number:")
        printDevices(devices)
        fail()
    }
    return FM1Updater(transport: transport, device: device, alsoProbing: portNames)
}

/// The names of the ports `--port NAME` matches, for the updater to probe as well as those that
/// look like an FM-1's; stops fm1probe if it matches none.
func chosenPortNames(_ transport: any MIDITransport) async -> Set<String> {
    guard let wanted = option("--port") else { return [] }
    let ports = await transport.ports()
    let names = ports.flatMap { [$0.name, $0.usbProductName].compactMap(\.self) }.filter { name in
        name.localizedCaseInsensitiveContains(wanted)
    }
    guard !names.isEmpty else {
        print("No port matches \"\(wanted)\". Run `fm1probe ports` to see their names.")
        fail()
    }
    return Set(names)
}

/// Prints devices numbered from 1, in the order `--device N` counts them.
func printDevices(_ devices: [FM1DeviceSummary]) {
    for (index, device) in devices.enumerated() {
        let state = device.isWaitingMidUpdate ? "update loader" : device.firmwareName ?? "firmware running"
        let serial = device.serialNumber.map { ", serial \($0)" } ?? ""
        print("  \(index + 1). \(device.identity.text)  (\(state))  on \(portLabel(device.port))\(serial)")
    }
}

/// A port's name, with the name its USB device reports now when macOS still shows an older one.
///
/// macOS keeps the name it first saw for a USB device's IDs and socket, so a firmware that shares
/// another's IDs, as CLEANSWEEP and ESTAMPIE do, can show under the other's name.
func portLabel(_ port: MIDIPortDescriptor) -> String {
    guard let current = port.usbProductName, current != port.name else { return port.name }
    return "\(current) (macOS still calls it \(port.name))"
}
