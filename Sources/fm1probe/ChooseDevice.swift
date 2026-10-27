import FM1Kit

/// Prints every device that answers, numbered for `--device`.
func listDevices() async throws {
    let devices = await FM1Updater(transport: try CoreMIDITransport(clientName: "fm1probe")).devices()
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
    let devices = await FM1Updater(transport: transport).devices()
    let wanted = option("--device")
    guard devices.count > 1 || wanted != nil else { return FM1Updater(transport: transport) }
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
    return FM1Updater(transport: transport, device: device)
}

/// Prints devices numbered from 1, in the order `--device N` counts them.
func printDevices(_ devices: [FM1DeviceSummary]) {
    for (index, device) in devices.enumerated() {
        let state = device.isWaitingMidUpdate ? "update loader" : device.firmwareName ?? "firmware running"
        let serial = device.serialNumber.map { ", serial \($0)" } ?? ""
        print("  \(index + 1). \(device.identity.text)  (\(state))  on \(device.portName)\(serial)")
    }
}
