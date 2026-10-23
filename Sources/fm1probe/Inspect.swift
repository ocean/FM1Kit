import FM1Kit
import Foundation

/// Shows what a package holds, or which m-bootloader a `.boot` file holds; sends nothing.
func inspect(path: String) throws {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    if path.lowercased().hasSuffix(".boot") {
        guard let bootloader = BootloaderImage(data: data) else {
            print("This isn't an m-bootloader .boot file, or it's damaged.")
            exit(1)
        }
        print("Bootloader:    m-bootloader \(bootloader.version) for \(bootloader.board), checksums intact")
        print("Size:          \(bootloader.bytes.count) bytes")
        print("SHA-256:       \(bootloader.sha256)")
        return
    }
    let package = try FwscPackage(data: data)
    print("Product:       \(package.product)")
    print("File size:     \(package.fileBytes.count) bytes")
    print("Logical image: \(package.logicalImage.count) bytes")
    print("SHA-256:       \(package.sha256)")
    print("Contents:      header, parts and checksums all intact")
    let isStockLoader = package.loaderSHA256 == OfficialFirmware.stockLoaderSHA256
    print("Loader:        \(package.loaderSHA256)\(isStockLoader ? " (M-VAVE's, reports ota-FM-1_015)" : "")")
    if let official = OfficialFirmware.matching(package) {
        print("Official:      \(official.name) (verified)")
    }
    if package.hasFactoryVoices {
        print("Voices:        V15's 128 factory voices (fm1probe restore-voices can restore them)")
    }
    if !package.isFirmware {
        do {
            let installer = try BootloaderInstaller(package: package)
            let bootloader = installer.bootloader
            print("Installs:      m-bootloader \(bootloader.version) for \(bootloader.board), no firmware")
            print("Bootloader:    \(bootloader.bytes.count) bytes, SHA-256 \(bootloader.sha256)")
            print("               (fm1probe install-bootloader can install it from V15)")
        } catch {
            print("Installs:      an installer, not firmware: \(error.localizedDescription)")
        }
    }
}
