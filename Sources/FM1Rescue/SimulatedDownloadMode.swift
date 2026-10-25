#if os(macOS)
import Foundation

/// A software FM-1 in the chip's download mode, for tests and previews: its ROM takes the flash
/// loader, and the loader answers from 1 MB of simulated flash.
public final class SimulatedDownloadMode: DownloadModeConnection {
    /// The simulated flash.
    public private(set) var flash: [UInt8]
    /// The chip's encryption key.
    public var chipKey: UInt16 = 0x980F
    /// The flash chip's JEDEC ID: 1 MB.
    public var flashID: UInt32 = 0x85_6014
    /// The flash chip's unique ID.
    public var uniqueID: [UInt8] = Array("SIMULATE".utf8)
    /// Flip a bit in every read after this many, as an unreliable connection might.
    public var corruptsReadsAfter: Int?
    /// Pretend another tool's loader is already running.
    public var hasOtherLoader = false
    /// Flip a bit at this address when it's programmed, as a failing flash chip might.
    public var failsWritesAt: Int?
    /// How many times ``failsWritesAt`` fails before writes there succeed.
    public var writeFailures = Int.max
    /// The loader's write buffer in bytes, or `nil` to refuse the command, as JieLi's loader may.
    public var bufferSize: Int? = 4096
    /// Stop answering after this many flash writes, as a pulled cable would.
    public var disconnectsAfterWrites: Int?
    /// The 64 KB block erases so far.
    public private(set) var blockErases = 0
    /// The flash writes so far, each up to the write buffer's size.
    public private(set) var flashWrites = 0
    /// The rows of text on the FM-1's display, once the loader has switched it on.
    public private(set) var screen: [Int: String] = [:]
    /// The progress bar's percentage on the FM-1's display.
    public private(set) var progressBar = 0
    /// The 4 KB sectors erased so far, by address, in order.
    public private(set) var erasedSectors: [Int] = []
    /// True after ``close()``.
    public private(set) var isClosed = false

    /// The loader that's running, if one has been uploaded and started.
    public private(set) var runningLoaderVersion: String?
    private var runningAddress: UInt32 = 0
    private var memory: [UInt32: [UInt8]] = [:]
    private var reads = 0

    /// A simulated chip with this flash.
    ///
    /// - Parameter flash: 1 MB of flash; ``sampleFlash(bootloader:)`` makes one.
    public init(flash: [UInt8] = SimulatedDownloadMode.sampleFlash()) {
        self.flash = flash
    }

    /// 1 MB of patterned flash, with a bootloader container stored in the boot area as the chip
    /// stores it, if one is given.
    ///
    /// - Parameter bootloader: A `.boot` container to store at `0xA0`.
    /// - Returns: The flash.
    public static func sampleFlash(bootloader: [UInt8]? = nil) -> [UInt8] {
        var flash = (0..<FlashSession.flashSize).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ ($0 >> 12)) }
        if let bootloader, bootloader.count > 16 {
            let start = FlashBackup.bootloaderOffset
            let stored = FlashBackup.decipher(bootloader[0..<16]) + FlashBackup.decipher(bootloader[16...])
            flash.replaceSubrange(start..<(start + stored.count), with: stored)
        }
        return flash
    }

    /// Answers a command as the chip's ROM, or the loader once it's running, would.
    ///
    /// - Parameters:
    ///   - command: The command block.
    ///   - phase: Which way data moves after the command, if at all.
    /// - Returns: The bytes the chip sends back.
    /// - Throws: ``DownloadModeError/commandFailed(_:)`` for a command the chip refuses.
    public func execute(_ command: [UInt8], _ phase: DataPhase) throws(DownloadModeError) -> [UInt8] {
        guard !isClosed else { throw .transferFailed("the connection is closed") }
        if command == ChipCommand.inquiry {
            return [0, 0x80, 2, 2, 31, 0, 0, 0] + Self.padded("WL82", 8) + Self.padded("UBOOT1.00", 16)
                + Self.padded("1.00", 4)
        }
        let opcode = UInt16(ChipCommand.readBigEndian(command, at: 0, byteCount: 2))
        switch opcode {
        case ChipCommand.writeMemory:
            guard case .send(let block) = phase,
                Int(ChipCommand.readBigEndian(command, at: 6, byteCount: 2)) == block.count,
                UInt16(command[9]) | UInt16(command[10]) << 8 == ChipChecksum.crc16(block)
            else {
                throw .commandFailed("memory write")
            }
            memory[ChipCommand.readBigEndian(command, at: 2, byteCount: 4)] = ChipChecksum.scramble(block)
            return []
        case ChipCommand.jump:
            jump(to: ChipCommand.readBigEndian(command, at: 2, byteCount: 4))
            return Self.reply(opcode)
        default:
            return try loaderCommand(opcode, command, phase)
        }
    }

    /// Ends the simulated connection.
    public func close() {
        isClosed = true
    }

    /// Starts the uploaded loader, if what was uploaded there is one of m-bootloader's.
    private func jump(to address: UInt32) {
        var uploaded: [UInt8] = []
        var next = address
        while let block = memory[next] {
            uploaded += block
            next += UInt32(block.count)
        }
        if let loader = FlashLoaderImage.bundled.first(where: { $0.address == address && $0.bytes == uploaded }) {
            runningLoaderVersion = loader.version
            runningAddress = address
            hasOtherLoader = false
        }
    }

    /// Answers the flash loader's commands; the ROM alone refuses them.
    private func loaderCommand(_ opcode: UInt16, _ command: [UInt8], _ phase: DataPhase) throws(DownloadModeError)
        -> [UInt8]
    {
        if hasOtherLoader, opcode == ChipCommand.onlineDevice { return Self.reply(opcode, [3, 0]) }
        guard let version = runningLoaderVersion else { throw .commandFailed(String(format: "0x%04x", opcode)) }
        let address = Int(ChipCommand.readBigEndian(command, at: 2, byteCount: 4))
        switch opcode {
        case ChipCommand.identify:
            return Self.reply(
                opcode,
                Array("MFLR\(version)".utf8) + [0] + ChipCommand.bigEndian(runningAddress, byteCount: 4) + [
                    0x0F, 96,
                ])
        case ChipCommand.readKey:
            let scrambled = ChipChecksum.scramble([UInt8(chipKey & 0xFF), UInt8(chipKey >> 8)])
            return Self.reply(opcode, [0, 0, 0, 0, scrambled[1], scrambled[0]])
        case ChipCommand.onlineDevice:
            return Self.reply(opcode, [3, 0] + (0..<3).map { UInt8(truncatingIfNeeded: flashID >> (8 * $0)) })
        case ChipCommand.uniqueID:
            return Self.reply(opcode, uniqueID)
        case ChipCommand.crc32:
            let length = Int(ChipCommand.readBigEndian(command, at: 6, byteCount: 4))
            return Self.reply(
                opcode, ChipCommand.bigEndian(ChipChecksum.crc32(flash[address..<(address + length)]), byteCount: 4)
            )
        case ChipCommand.readFlash:
            let length = Int(ChipCommand.readBigEndian(command, at: 6, byteCount: 2))
            var part = Array(flash[address..<(address + length)])
            reads += 1
            if let limit = corruptsReadsAfter, reads > limit { part[0] ^= 1 }
            return part
        default:
            return try writingCommand(opcode, command, phase)
        }
    }

    /// Answers the loader's erase, write and display commands.
    private func writingCommand(_ opcode: UInt16, _ command: [UInt8], _ phase: DataPhase) throws(DownloadModeError)
        -> [UInt8]
    {
        let address = Int(ChipCommand.readBigEndian(command, at: 2, byteCount: 4))
        switch opcode {
        case ChipCommand.eraseBlock, ChipCommand.eraseSector:
            let length = opcode == ChipCommand.eraseBlock ? 0x1_0000 : 0x1000
            guard address.isMultiple(of: length), address + length <= flash.count else {
                throw .commandFailed(String(format: "0x%04x", opcode))
            }
            flash.replaceSubrange(address..<(address + length), with: repeatElement(0xFF, count: length))
            erasedSectors += stride(from: address, to: address + length, by: 0x1000)
            if opcode == ChipCommand.eraseBlock { blockErases += 1 }
            return Self.reply(opcode)
        case ChipCommand.writeFlash:
            if let limit = disconnectsAfterWrites, flashWrites >= limit { throw .transferFailed("the device is gone") }
            try program(command, phase)
            flashWrites += 1
            return []
        case ChipCommand.bufferSize:
            guard let bufferSize else { throw .commandFailed(String(format: "0x%04x", opcode)) }
            return Self.reply(opcode, ChipCommand.bigEndian(UInt32(bufferSize), byteCount: 4))
        case ChipCommand.displayOn:
            return Self.reply(opcode, [command[2] == 1 ? 1 : 0])
        case ChipCommand.displayText:
            if case .send(let text) = phase {
                screen[Int(command[2])] = String(bytes: text, encoding: .ascii)
            }
            return []
        case ChipCommand.displayBar:
            progressBar = min(Int(command[2]), 100)
            return Self.reply(opcode)
        default:
            throw .commandFailed(String(format: "0x%04x", opcode))
        }
    }

    /// Programs flash as NOR flash does: bits only go from 1 to 0, so it must be erased first.
    private func program(_ command: [UInt8], _ phase: DataPhase) throws(DownloadModeError) {
        let address = Int(ChipCommand.readBigEndian(command, at: 2, byteCount: 4))
        let length = Int(ChipCommand.readBigEndian(command, at: 6, byteCount: 2))
        guard case .send(let data) = phase, data.count == length, length <= 4096,
            address + length <= flash.count,
            UInt16(command[9]) | UInt16(command[10]) << 8 == ChipChecksum.crc16(data)
        else {
            throw .commandFailed("flash write")
        }
        for (offset, byte) in data.enumerated() {
            flash[address + offset] &= byte
            if address + offset == failsWritesAt, writeFailures > 0 {
                flash[address + offset] ^= 1
                writeFailures -= 1
            }
        }
    }

    /// A 16-byte answer: the opcode, then `payload`, then zeros.
    private static func reply(_ opcode: UInt16, _ payload: [UInt8] = []) -> [UInt8] {
        let bytes = ChipCommand.bigEndian(UInt32(opcode), byteCount: 2) + payload
        return bytes + [UInt8](repeating: 0, count: 16 - bytes.count)
    }

    private static func padded(_ text: String, _ length: Int) -> [UInt8] {
        Array(text.utf8) + [UInt8](repeating: 0x20, count: length - text.utf8.count)
    }
}
#endif
