import FM1Kit
import FM1Rescue
import Foundation

/// Runs `flash-image`, making the flash image for the FM-1 Transporter's web app to write.
///
/// It's made from a firmware package and the Transporter's backup of the FM-1, talking to no device.
///
/// - Parameter arguments: The command, the package, the backup and the image to save, then options.
/// - Throws: Any error reading a file or saving the image.
func makeTransporterImage(_ arguments: [String]) throws {
    guard arguments.count >= 4 else {
        print(usage)
        exit(1)
    }
    let packagePath = arguments[1]
    let backupPath = arguments[2]
    let imageURL = URL(fileURLWithPath: arguments[3])
    let package = try FwscPackage(data: Data(contentsOf: URL(fileURLWithPath: packagePath)))
    let backup = try FlashBackup(contentsOf: URL(fileURLWithPath: backupPath))

    let flashID: UInt32?
    if let text = option("--flash-id") {
        guard let id = UInt32(text.replacingOccurrences(of: "0x", with: ""), radix: 16) else {
            print("--flash-id takes the flash ID in hex, such as 856014.")
            exit(1)
        }
        flashID = id
    } else if backup.flashID == 0 {
        print(
            """
            \(backupPath) has no .json beside it saying which flash chip it came from. Add the flash \
            ID the Transporter showed when it checked the FM-1, such as --flash-id 856014.
            """)
        exit(1)
    } else {
        flashID = nil
    }

    print("Backup:     \(backupPath), sha256 \(backup.sha256)")
    print("Bootloader: \(backup.bootloaderDescription)")
    print("Firmware:   \(describeFirmware(backup))")
    let plan: FlashPlan
    do {
        plan = try FlashPlan.installingWithTransporter(package, onto: backup, flashID: flashID)
    } catch {
        print("Stopped: \(error.localizedDescription)")
        exit(1)
    }
    print("")
    for note in plan.notes { print(note) }
    for warning in plan.warnings { print("Warning: \(warning)") }
    guard !plan.isEmpty else {
        print("Nothing to write: the backup already holds this firmware, so no image was made.")
        return
    }
    let runs = plan.runs.map { String(format: "0x%05X–0x%05X", $0.lowerBound, $0.upperBound - 1) }
    print("The Transporter will write \(plan.sectors.count) sectors of 4 KB: \(runs.joined(separator: ", ")).")

    do {
        try Data(plan.target).write(to: imageURL, options: .withoutOverwriting)
    } catch CocoaError.fileWriteFileExists {
        print("\(imageURL.path) already exists. Choose a new file for the image.")
        exit(1)
    }
    print(
        """

        Saved the image in \(imageURL.path), sha256 \(FwscPackage.sha256Hex(plan.target)).
        Outside 0x04000–0x92FFF it's the backup unchanged. In the web app, choose it at Write in \
        the same session as the backup: it writes only if the FM-1 still matches that backup.
        """)
}
