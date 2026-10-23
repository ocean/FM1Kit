@_spi(Testing) import FM1Kit
import Foundation
import Testing

@testable import FM1Rescue

/// Download mode against the simulated chip, and the command layouts m-bootloader's
/// specification gives (§10.2).
struct DownloadModeTests {
    @Test func laysOutCommandsAsTheSpecificationShows() {
        let write = ChipCommand.block(
            0xFB04, ChipCommand.memoryWriteArguments(address: 0x4000, block: Array("123456789".utf8)))
        #expect(write == [0xFB, 0x04, 0, 0, 0x40, 0, 0, 0x09, 0, 0xC3, 0x31, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        let read = ChipCommand.block(
            ChipCommand.readFlash,
            ChipCommand.bigEndian(0x4000, byteCount: 4) + ChipCommand.bigEndian(0x4000, byteCount: 2))
        #expect(read == [0xFD, 0x05, 0, 0, 0x40, 0, 0x40, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        let crc = ChipCommand.block(
            ChipCommand.crc32, ChipCommand.bigEndian(0, byteCount: 4) + ChipCommand.bigEndian(0x10_0000, byteCount: 4))
        #expect(crc == [0xFC, 0x41, 0, 0, 0, 0, 0, 0x10, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
    }

    @Test func scramblesTheChipKeyAsTheSpecificationShows() {
        // Key 980F travels as 3C 20 at reply +6 and +7.
        #expect(ChipChecksum.scramble([0x0F, 0x98]) == [0x20, 0x3C])
        #expect(ChipChecksum.scramble(ChipChecksum.scramble([1, 2, 3])) == [1, 2, 3])
        #expect(ChipChecksum.crc32(Array("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test func recognisesIOUSBHostStalls() {
        // IOUSBHost reports kUSBHostReturnPipeStalled, not the older family's kIOUSBPipeStalled.
        #expect(USBDownloadModeConnection.pipeStalledCodes.contains(Int(Int32(bitPattern: 0xE000_5000))))
    }

    @Test func skipsOnlyEarlierStatusBlocks() {
        // A real leftover: the FM-1's ROM sent tag 9's status in answer to tag 10.
        let leftover: [UInt8] = [0x55, 0x53, 0x42, 0x53, 0x09, 0, 0, 0, 0, 0, 0, 0, 0x01]
        #expect(USBDownloadModeConnection.isStaleStatus(leftover, expecting: 10))
        #expect(!USBDownloadModeConnection.isStaleStatus(leftover, expecting: 9))
        #expect(!USBDownloadModeConnection.isStaleStatus(leftover, expecting: 30))
        #expect(!USBDownloadModeConnection.isStaleStatus(Array(leftover.prefix(12)), expecting: 10))
    }

    @Test func bundlesBothLoaders() {
        #expect(FlashLoaderImage.bundled.map(\.address) == [0x01C2_0000, 0x01C2_8000])
        #expect(FlashLoaderImage.bundled.map(\.version) == ["1.2", "1.2"])
    }

    @Test func startsTheLoaderAndReadsTheChip() throws {
        let chip = SimulatedDownloadMode()
        let session = try FlashSession(connection: chip)
        #expect(chip.runningLoaderVersion == "1.2")
        #expect(session.loaderVersion == "1.2")
        #expect(session.clockMHz == 96)
        #expect(session.chipKey == 0x980F)
        #expect(session.flashID == 0x85_6014)
        #expect(session.uniqueID == "53494d554c415445")
        #expect(try session.read(0x1000..<0x1010) == Array(chip.flash[0x1000..<0x1010]))
    }

    @Test func reusesALoaderThatsRunning() throws {
        let chip = SimulatedDownloadMode()
        _ = try FlashSession(connection: chip)
        let again = try FlashSession(connection: chip)
        #expect(again.loaderVersion == "1.2")
    }

    @Test func refusesWhenAnotherLoaderIsRunning() {
        let chip = SimulatedDownloadMode()
        chip.hasOtherLoader = true
        #expect(throws: DownloadModeError.otherLoaderRunning) { try FlashSession(connection: chip) }
    }

    @Test func refusesADeviceThatIsntDownloadMode() {
        #expect(throws: DownloadModeError.notDownloadMode("Apple Disk")) { try FlashSession(connection: OtherDisk()) }
    }

    @Test func backsUpTheWholeFlash() throws {
        let chip = SimulatedDownloadMode(
            flash: SimulatedDownloadMode.sampleFlash(bootloader: BootloaderImage.sample().bytes))
        var fractions: [Double] = []
        let backup = try FlashSession(connection: chip).backUp { fractions.append($0) }
        #expect(backup.bytes == chip.flash)
        #expect(backup.uniqueID == "53494d554c415445")
        #expect(backup.mBootloader == .sample())
        #expect(backup.bootloaderDescription == "m-bootloader 1.2-sample")
        #expect(fractions.first == 0)
        #expect(fractions.last == 1)
        #expect(fractions == fractions.sorted())
    }

    @Test func recognisesABootAreaWithoutM_Bootloader() throws {
        let backup = try FlashSession(connection: SimulatedDownloadMode()).backUp()
        #expect(backup.mBootloader == nil)
        #expect(backup.bootloaderDescription == "unreadable")
    }

    @Test func refusesReadsThatDiffer() {
        let chip = SimulatedDownloadMode()
        chip.corruptsReadsAfter = 64
        #expect(throws: DownloadModeError.readsDiffer) { try FlashSession(connection: chip).backUp() }
    }

    @Test func savesAsM_FlasherDoes() throws {
        let backup = try FlashSession(connection: SimulatedDownloadMode()).backUp()
        let folder = FileManager.default.temporaryDirectory.appending(path: "fm1rescue-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try backup.write(to: folder)
        let second = try backup.write(to: folder)
        #expect(first.flash.lastPathComponent.hasPrefix("fm1-"))
        #expect(second.flash.lastPathComponent.hasSuffix("-2.bin"))
        #expect(try Data(contentsOf: first.flash) == Data(backup.bytes))
        let description = try String(contentsOf: first.description, encoding: .utf8)
        // M-Flasher reads the unit ID back with exactly this spacing.
        #expect(description.contains("\"unit id\": \"53494d554c415445\""))
        #expect(description.contains("\"sha256\": \"\(backup.sha256)\""))
        let json = try JSONSerialization.jsonObject(with: Data(description.utf8)) as? [String: String]
        #expect(json?["chip key"] == "0x980F")
    }
}

/// A USB disk that isn't the chip's download mode.
private final class OtherDisk: DownloadModeConnection {
    func execute(_: [UInt8], _: DataPhase) throws(DownloadModeError) -> [UInt8] {
        [UInt8](repeating: 0, count: 8) + Array("Apple   Disk            ".utf8) + [UInt8](repeating: 0, count: 4)
    }

    func close() {}
}
