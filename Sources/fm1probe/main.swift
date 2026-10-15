// A small Mac command-line probe: talk to a real FM-1 over CoreMIDI and inspect .fwsc files.
// It never writes to the device.

import FM1Kit
import Foundation

let usage = """
usage: fm1probe ports              list MIDI port pairs and which would be probed
       fm1probe identify           ask the connected FM-1 what it is running
       fm1probe inspect FILE.fwsc  show a package's identity, size and hash
"""

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case "ports":
    let transport = try CoreMIDITransport(clientName: "fm1probe")
    let ports = await transport.ports()
    if ports.isEmpty { print("No MIDI port pairs found.") }
    for port in ports {
        print("\(FM1Updater.isProbeable(port) ? "probe" : "skip ")  \(port.name)  [\(port.id)]")
    }

case "identify":
    let transport = try CoreMIDITransport(clientName: "fm1probe")
    let updater = FM1Updater(transport: transport)
    if let identity = await updater.identify() {
        print("Device reports: \(identity.text)")
        print(identity.isLoader ? "The update loader is running (mid-update or USB rescue)." : "Firmware is running.")
    } else {
        print("No FM-1 answered the handshake.")
        exit(1)
    }

case "inspect" where arguments.count == 2:
    let data = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
    let package = try FwscPackage(data: data)
    print("Product:       \(package.product)")
    print("File size:     \(package.fileBytes.count) bytes")
    print("Logical image: \(package.logicalImage.count) bytes")
    print("SHA-256:       \(package.sha256)")
    if let official = OfficialFirmware.matching(package) {
        print("Official:      \(official.name) (verified)")
    }

default:
    print(usage)
    exit(2)
}

