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
        #expect(json?["firmware"] == "none")
        #expect(json?["app"] == "none installed")
        let reread = try FlashBackup(contentsOf: first.flash)
        #expect(reread.bytes == backup.bytes)
        #expect(reread.uniqueID == backup.uniqueID)
        #expect(reread.chipKey == backup.chipKey)
        #expect(reread.flashID == backup.flashID)
    }
}

/// What a backup shows of the firmware in the app area.
struct FirmwareCheckTests {
    /// Code that names the identities a firmware might: its own and the one it updates from.
    static let code = Array("..FM-1_378001..FM-1_015..FM-1_12..".utf8) + [UInt8](repeating: 0x5A, count: 0x3000)

    @Test func readsTheFirmwaresFiles() {
        let firmware = Self.backup(Self.flash(storing: Self.code)).firmware
        #expect(firmware.files == .intact)
        #expect(firmware.filesDescription == "OK")
        #expect(firmware.identities == ["FM-1_015", "FM-1_378001"])
        #expect(!firmware.isOfficialV15)
        #expect(firmware.name == nil)
        #expect(firmware.description == "unknown, naming FM-1_015 and FM-1_378001")
    }

    @Test func namesTheCustomFirmwaresTriedOnAnFM1() {
        let felucca = Array("..FM-1_015..FM-1_916..FELUCCA v1.6.1..".utf8) + [UInt8](repeating: 0x5A, count: 0x3000)
        let amb = Array("..FM-1_7010300..FM-1_015..AMB-1 1.3..".utf8) + [UInt8](repeating: 0x5A, count: 0x3000)
        #expect(Self.backup(Self.flash(storing: felucca)).firmware.description == "Felucca 1.6.1 (FM-1_916)")
        #expect(Self.backup(Self.flash(storing: amb)).firmware.description == "AMB-1 1.3 (FM-1_7010300)")
    }

    @Test func doesntNameAForkThatSharesItsIdentity() {
        let hyp = Array("..FM-1_7010300..FM-1_015..HYP-1 1.3..".utf8) + [UInt8](repeating: 0x5A, count: 0x3000)
        let firmware = Self.backup(Self.flash(storing: hyp)).firmware
        #expect(firmware.name == nil)
        #expect(firmware.description == "unknown, naming FM-1_015 and FM-1_7010300")
    }

    @Test func findsADamagedFile() {
        var flash = Self.flash(storing: Self.code)
        flash[FlashBackup.applicationArea + 0x1000 + 100] ^= 1
        #expect(Self.backup(flash).firmware.files == .damaged)
    }

    @Test func findsAnInterruptedWrite() {
        var flash = Self.flash(storing: Self.code)
        let sector = FlashBackup.applicationArea + 0x2000
        flash.replaceSubrange(sector..<(sector + 0x1000), with: [UInt8](repeating: 0xFF, count: 0x1000))
        #expect(Self.backup(flash).firmware.files == .incomplete)
    }

    @Test func findsNoFirmware() throws {
        let firmware = try FlashSession(connection: SimulatedDownloadMode()).backUp().firmware
        #expect(firmware.files == .missing)
        #expect(firmware.description == "none")
    }

    @Test func findsIdentitiesOfThreeToEightDigits() {
        let text = Array("FM-1_015 FM-1_12 FM-1_8000012 FM-1_123456789 FM-1_".utf8)
        #expect(FlashBackup.identities(in: text) == ["FM-1_015", "FM-1_8000012"])
    }

    static func backup(_ flash: [UInt8]) -> FlashBackup {
        FlashBackup(
            bytes: flash,
            uniqueID: nil,
            chipKey: 0x980F,
            flashID: 0x85_6014,
            loaderVersion: "1.2",
            date: Date()
        )
    }

    /// Flash whose app area holds `code` as `app.bin`, enciphered as the chip stores it.
    static func flash(storing code: [UInt8]) -> [UInt8] {
        let codeAddress = 0x200
        var area = [UInt8](repeating: 0xFF, count: codeAddress + code.count)
        var entry = [UInt8](repeating: 0, count: 32)
        let crc = ChipChecksum.crc16(code)
        entry[2] = UInt8(crc & 0xFF)
        entry[3] = UInt8(crc >> 8)
        for (index, value) in [codeAddress, code.count].enumerated() {
            for byte in 0..<4 { entry[4 + 4 * index + byte] = UInt8(truncatingIfNeeded: value >> (8 * byte)) }
        }
        entry[12] = FlashBackup.fileAttribute
        entry.replaceSubrange(16..<23, with: Array("app.bin".utf8))
        let entryCRC = ChipChecksum.crc16(entry[2...])
        entry[0] = UInt8(entryCRC & 0xFF)
        entry[1] = UInt8(entryCRC >> 8)
        area.replaceSubrange(0..<32, with: entry)
        area.replaceSubrange(codeAddress..<area.count, with: code)
        area += [UInt8](repeating: 0xFF, count: (32 - area.count % 32) % 32)
        var flash = SimulatedDownloadMode.sampleFlash()
        for block in stride(from: 0, to: area.count, by: 32) {
            let key = 0x980F ^ UInt16(truncatingIfNeeded: block >> 2)
            let start = FlashBackup.applicationArea + block
            let stored = FlashBackup.decipher(area[block..<(block + 32)], key: key)
            flash.replaceSubrange(start..<(start + 32), with: stored)
        }
        return flash
    }
}

/// A USB disk that isn't the chip's download mode.
private final class OtherDisk: DownloadModeConnection {
    func execute(_: [UInt8], _: DataPhase) throws(DownloadModeError) -> [UInt8] {
        [UInt8](repeating: 0, count: 8) + Array("Apple   Disk            ".utf8) + [UInt8](repeating: 0, count: 4)
    }

    func close() {}
}
