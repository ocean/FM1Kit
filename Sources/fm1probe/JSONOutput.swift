import FM1Kit
import FM1Rescue
import Foundation

// `--json` output for scripts and CI: one JSON object on standard output, with a `format` naming
// its layout and version, such as "fm1probe-check-1". A new field keeps the version; a field
// that changes or goes away moves it on.

// The JSON types' properties are read only by the encoder Swift writes for them.
// swiftlint:disable unused_declaration

/// True when the command should print JSON rather than text.
let isJSON = arguments.contains("--json")

/// Prints a line that isn't part of the JSON: to standard error in JSON mode, so standard output
/// stays one JSON object.
func printAside(_ line: String) {
    if isJSON {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    } else {
        print(line)
    }
}

/// Prints `value` as JSON on standard output.
func printJSON(_ value: some Encodable) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
        printAside("fm1probe couldn't write its JSON.")
        exit(1)
    }
    print(text)
}

/// A flash chip as JSON: its JEDEC ID in hex, and its name when it's one FM-1s have.
struct FlashChipJSON: Encodable {
    let id: String
    let name: String?

    init(_ id: UInt32) {
        self.id = String(format: "0x%06X", id)
        name = FM1FlashChip.name(id)
    }
}

/// A MIDI port as JSON.
struct PortJSON: Encodable {
    let id: String
    let name: String
    let usbProductName: String?
    let serialNumber: String?

    init(_ port: MIDIPortDescriptor) {
        id = port.id
        name = port.name
        usbProductName = port.usbProductName
        serialNumber = port.serialNumber
    }
}

/// Why a command couldn't do its work, as JSON.
struct ErrorJSON: Encodable {
    let format: String
    let file: String?
    let error: String
}

// MARK: - check.

/// `check --json`.
struct CheckJSON: Encodable {
    let format = "fm1probe-check-1"
    let file: String
    let product: String
    let sha256: String
    let passes: Bool
    let worst: PackageCheck.Outcome
    let findings: [PackageCheck.Finding]
}

// MARK: - devices.

/// `devices --json`.
struct DevicesJSON: Encodable {
    /// A device that answered.
    struct Device: Encodable {
        let number: Int
        let identity: String
        let isUpdateLoader: Bool
        let firmwareName: String?
        let firmwareVersion: String?
        let flashChip: FlashChipJSON?
        let port: PortJSON
    }

    let format = "fm1probe-devices-1"
    let devices: [Device]

    init(_ devices: [FM1DeviceSummary]) {
        self.devices = devices.enumerated().map { index, device in
            Device(
                number: index + 1,
                identity: device.identity.text,
                isUpdateLoader: device.isWaitingMidUpdate,
                firmwareName: device.firmwareName,
                firmwareVersion: device.firmwareVersion,
                flashChip: device.flashChipID.map(FlashChipJSON.init),
                port: PortJSON(device.port)
            )
        }
    }
}

// MARK: - identify.

/// `identify --json`.
struct IdentifyJSON: Encodable {
    /// What one port answered.
    struct Port: Encodable {
        let port: PortJSON
        let attempts: Int
        let answered: Int
        /// The first reply, in hex.
        let reply: String?
        let identities: [String]
        /// "firmware" or "updateLoader"; left out when nothing answered.
        let running: String?
        let flashChip: FlashChipJSON?
        let replyMilliseconds: Timing?
    }

    /// Reply times in milliseconds.
    struct Timing: Encodable {
        let average: Int
        let fastest: Int
        let slowest: Int
    }

    let format = "fm1probe-identify-1"
    let ports: [Port]
}

// MARK: - inspect.

/// `inspect --json` on a package, a `.boot` file or a flash backup.
struct InspectJSON: Encodable {
    /// An m-bootloader.
    struct Bootloader: Encodable {
        let version: String
        let board: String
        let size: Int
        let sha256: String

        init(_ bootloader: BootloaderImage) {
            version = bootloader.version
            board = bootloader.board
            size = bootloader.bytes.count
            sha256 = bootloader.sha256
        }
    }

    /// A `.fwsc` package.
    struct Package: Encodable {
        let product: String
        let fileSize: Int
        let logicalImageSize: Int
        let sha256: String
        let isFirmware: Bool
        let loaderSHA256: String
        let hasMVAVEsLoader: Bool
        let official: String?
        let flashChips: String?
        let hasFactoryVoices: Bool
        let updateCode: UpdateCode?
        let installs: Bootloader?
        let installerError: String?
    }

    /// A flash backup.
    struct FlashBackup: Encodable {
        let size: Int
        let sha256: String
        let unitID: String?
        let bootloader: String
        let firmware: String
        let files: String
    }

    let format = "fm1probe-inspect-1"
    let file: String
    let kind: String
    var package: Package?
    var bootloader: Bootloader?
    var flashBackup: FlashBackup?
}

extension InspectJSON.Package {
    init(_ package: FwscPackage) {
        var installs: InspectJSON.Bootloader?
        var installerError: String?
        if !package.isFirmware {
            do {
                installs = InspectJSON.Bootloader(try BootloaderInstaller(package: package).bootloader)
            } catch {
                installerError = error.localizedDescription
            }
        }
        self.init(
            product: package.product,
            fileSize: package.fileBytes.count,
            logicalImageSize: package.logicalImage.count,
            sha256: package.sha256,
            isFirmware: package.isFirmware,
            loaderSHA256: package.loaderSHA256,
            hasMVAVEsLoader: package.loaderSHA256 == OfficialFirmware.stockLoaderSHA256,
            official: OfficialFirmware.matching(package)?.name,
            flashChips: package.flashChipSupport.map { support in
                switch support {
                case .bothChips: "both"
                case .firstChipOnly: "firstOnly"
                case .noCheck: "noCheck"
                }
            },
            hasFactoryVoices: package.hasFactoryVoices,
            updateCode: package.updateCode,
            installs: installs,
            installerError: installerError
        )
    }
}

extension InspectJSON.FlashBackup {
    init(_ backup: FM1Rescue.FlashBackup) {
        let firmware = backup.firmware
        self.init(
            size: backup.bytes.count,
            sha256: backup.sha256,
            unitID: backup.uniqueID,
            bootloader: backup.bootloaderDescription,
            firmware: firmware.description,
            files: String(describing: firmware.files)
        )
    }
}

// swiftlint:enable unused_declaration
