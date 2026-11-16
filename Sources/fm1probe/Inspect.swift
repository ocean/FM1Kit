import FM1Kit
import FM1Rescue
import Foundation

/// Shows what a package holds, which m-bootloader a `.boot` file holds, or what a flash backup
/// holds; sends nothing.
func inspect(path: String) throws {
    if isJSON {
        try inspectAsJSON(path: path)
        return
    }
    if path.lowercased().hasSuffix(".bin") {
        try inspectFlashBackup(URL(fileURLWithPath: path))
        return
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    if path.lowercased().hasSuffix(".boot") {
        inspectBootloaderFile(data)
        return
    }
    let package = try FwscPackage(data: data)
    Style.heading("Package")
    print(Style.bold("Product:") + "       \(package.product)")
    print(Style.bold("File size:") + "     \(package.fileBytes.count) bytes")
    print(Style.bold("Logical image:") + " \(package.logicalImage.count) bytes")
    print(Style.bold("SHA-256:") + "       \(package.sha256)")
    print(Style.bold("Contents:") + "      header, parts and checksums all intact")
    let isStockLoader = package.loaderSHA256 == OfficialFirmware.stockLoaderSHA256
    print(
        Style.bold("Loader:")
            + "        \(package.loaderSHA256)\(isStockLoader ? " (M-VAVE's, reports ota-FM-1_015)" : "")")
    if let support = package.flashChipSupport {
        print(Style.bold("Flash chips:") + "   " + flashChipSupportDescription(support))
    }
    if let official = OfficialFirmware.matching(package) {
        print(Style.bold("Official:") + "      \(official.name) (verified)")
    }
    if package.hasFactoryVoices {
        print(Style.bold("Voices:") + "        V15's 128 factory voices (fm1probe restore-voices can restore them)")
    }
    printResources(of: package)
    if package.refusesV15OverOtherBootloaders {
        print(Style.bold("Update code:") + "   Felucca's platform: once installed, it refuses V15 over USB-MIDI while")
        print("               m-bootloader is installed (install MIDIMON 0.5 first then,")
        print("               or V15 in download mode)")
    } else if package.usesFeluccaUpdateCode {
        print(Style.bold("Update code:") + "   Felucca's platform: once installed, it takes V15 over USB-MIDI")
        print("               whichever bootloader is installed")
    }
    if !package.isFirmware {
        do {
            let installer = try BootloaderInstaller(package: package)
            let bootloader = installer.bootloader
            print(
                Style.bold("Installs:")
                    + "      m-bootloader \(bootloader.version) for \(bootloader.board), no firmware")
            print(Style.bold("Bootloader:") + "    \(bootloader.bytes.count) bytes, SHA-256 \(bootloader.sha256)")
            print("               (fm1probe install-bootloader can install it from V15)")
        } catch {
            print(Style.bold("Installs:") + "      an installer, not firmware: \(error.localizedDescription)")
        }
    }
}

/// Shows which m-bootloader a `.boot` file holds.
private func inspectBootloaderFile(_ data: Data) {
    guard let bootloader = BootloaderImage(data: data) else {
        stop("This isn't an m-bootloader .boot file, or it's damaged.")
    }
    Style.heading("Bootloader file")
    let description = "m-bootloader \(bootloader.version) for \(bootloader.board), checksums intact"
    print(Style.bold("Bootloader:") + "    " + description)
    print(Style.bold("Size:") + "          \(bootloader.bytes.count) bytes")
    print(Style.bold("SHA-256:") + "       \(bootloader.sha256)")
}

/// Shows which bootloader and firmware a full flash backup holds.
private func inspectFlashBackup(_ url: URL) throws {
    let backup = try FlashBackup(contentsOf: url)
    let firmware = backup.firmware
    Style.heading("Flash backup")
    print(Style.bold("Flash backup:") + "  \(backup.bytes.count) bytes, SHA-256 \(backup.sha256)")
    print(Style.bold("Unit ID:") + "       \(backup.uniqueID ?? "unknown (no .json beside it)")")
    print(Style.bold("Bootloader:") + "    \(backup.bootloaderDescription)")
    print(Style.bold("Firmware:") + "      \(firmware.description)")
    print(Style.bold("Files:") + "         \(firmware.filesDescription)")
}

/// What a firmware's flash chip check means for the person installing it.
func flashChipSupportDescription(_ support: FlashChipSupport) -> String {
    switch support {
    case .bothChips: "checks for both, so it saves on FM-1s with the newer chip (0xB36014)"
    case .firstChipOnly:
        "checks for the first FM-1s' (0x856014) alone: on the newer chip it may keep saves only until switched off"
    case .noCheck: "doesn't check which chip it has"
    }
}

/// `inspect --json`: what the file holds, as JSON.
private func inspectAsJSON(path: String) throws {
    let url = URL(fileURLWithPath: path)
    do {
        if path.lowercased().hasSuffix(".bin") {
            var json = InspectJSON(file: path, kind: "flashBackup")
            json.flashBackup = InspectJSON.FlashBackup(try FlashBackup(contentsOf: url))
            printJSON(json)
            return
        }
        let data = try Data(contentsOf: url)
        if path.lowercased().hasSuffix(".boot") {
            guard let bootloader = BootloaderImage(data: data) else {
                printJSON(
                    ErrorJSON(
                        format: "fm1probe-inspect-1",
                        file: path,
                        error: "This isn't an m-bootloader .boot file, or it's damaged."))
                exit(1)
            }
            var json = InspectJSON(file: path, kind: "bootloader")
            json.bootloader = InspectJSON.Bootloader(bootloader)
            printJSON(json)
            return
        }
        var json = InspectJSON(file: path, kind: "package")
        json.package = InspectJSON.Package(try FwscPackage(data: data))
        printJSON(json)
    } catch {
        printJSON(ErrorJSON(format: "fm1probe-inspect-1", file: path, error: error.localizedDescription))
        exit(1)
    }
}

/// Says where a package's resources go, if it carries any.
private func printResources(of package: FwscPackage) {
    if let resources = package.resources, let range = resources.flashRange {
        let flash = String(format: "0x%05X–0x%05X", range.lowerBound, range.upperBound - 1)
        print(
            Style.bold("Resources:") + "     \(resources.payloadLength) bytes at \(flash), written by its update loader"
        )
    } else if package.carriesOtherResources {
        print(
            Style.bold("Resources:")
                + "     in another form than fm1-base's (Melodee's), written by its update loader only")
    }
}
