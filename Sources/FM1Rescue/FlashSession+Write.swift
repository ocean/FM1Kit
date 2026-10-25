#if os(macOS)

// Writing follows M-Flasher's `ops.rs` and `jl.rs` (MIT License, Copyright (c) 2026 Julius
// Vitkauskas; see Resources/NOTICE.md) and m-bootloader's specification (§10).

extension FlashSession {
    /// Carries out a plan: erases and writes only the sectors that change, then checks each run
    /// of them against the chip's CRC-32, erasing and writing it once more if it doesn't match.
    ///
    /// Save ``FlashPlan/original`` before calling this: it's the way back. The FM-1 must still
    /// hold the flash the plan was made against, which is checked first. The FM-1's screen shows
    /// the progress and `DO NOT SWITCH OFF`. Switching the FM-1 off while it writes can leave it
    /// unable to start. If the boot area wasn't being written, m-bootloader still starts download
    /// mode (hold REC), so the backup can be restored; a damaged boot area can need a USB_KEY
    /// dongle.
    ///
    /// - Parameters:
    ///   - plan: What to write.
    ///   - progress: Called with the share written so far (0 to 1).
    /// - Throws: ``DownloadModeError/flashChanged`` before anything is written when the flash
    ///   isn't what the plan was made against (or anything else goes wrong before writing
    ///   starts), ``DownloadModeError/writeNotVerified(_:)`` when a run doesn't read back as
    ///   written twice, or ``DownloadModeError/writeInterrupted(at:_:)`` when the device stops
    ///   answering once writing has started.
    public func write(_ plan: FlashPlan, progress: (Double) -> Void = { _ in }) throws(DownloadModeError) {
        guard !plan.isEmpty else {
            progress(1)
            return
        }
        guard plan.original.uniqueID == uniqueID, plan.original.chipKey == chipKey,
            try crc32(of: 0..<Self.flashSize) == ChipChecksum.crc32(plan.original.bytes)
        else {
            throw .flashChanged
        }
        let chunkLength = writeChunkLength()
        let screen = UnitScreen(session: self, isFM1: plan.original.model == .fm1)
        progress(0)
        var address = plan.sectors[0]
        do {
            try write(plan, chunkLength: chunkLength, screen: screen, progress: progress, at: &address)
        } catch .writeNotVerified(let run) {
            throw .writeNotVerified(run)
        } catch .transferFailed(let detail) {
            throw .writeInterrupted(at: address, detail)
        } catch .commandFailed(let command) {
            throw .writeInterrupted(at: address, "it refused \(command)")
        } catch {
            throw .writeInterrupted(at: address, String(describing: error))
        }
    }

    /// Erases, writes and checks each run, keeping `address` at the sector being written.
    private func write(
        _ plan: FlashPlan,
        chunkLength: Int,
        screen: UnitScreen,
        progress: (Double) -> Void,
        at address: inout Int
    ) throws(DownloadModeError) {
        screen.show([
            UnitScreen.Row(3, " \(Self.screenTitle(plan.purpose))"),
            UnitScreen.Row(5, " WRITING"),
            UnitScreen.Row(12, " DO NOT SWITCH OFF", colour: UnitScreen.amber),
        ])
        var written = 0
        for run in plan.runs {
            var attempt = 1
            while true {
                address = run.lowerBound
                try erase(run)
                for sector in stride(from: run.lowerBound, to: run.upperBound, by: FlashPlan.sectorLength) {
                    address = sector
                    try program(Array(plan.target[sector..<(sector + FlashPlan.sectorLength)]), at: sector, chunkLength)
                    let done = written + (sector + FlashPlan.sectorLength - run.lowerBound) / FlashPlan.sectorLength
                    progress(Double(done) / Double(plan.sectors.count))
                    screen.progress(100 * done / plan.sectors.count)
                }
                if try crc32(of: run) == ChipChecksum.crc32(plan.target[run]) { break }
                guard attempt < 2 else { throw .writeNotVerified(run) }
                attempt += 1
            }
            written += run.count / FlashPlan.sectorLength
        }
        screen.show([
            UnitScreen.Row(5, " DONE - VERIFIED", colour: UnitScreen.mint),
            UnitScreen.Row(12, " SWITCH OFF AND ON"),
            UnitScreen.Row(13, " \(plan.sectors.count) SECTORS OK", colour: UnitScreen.mint),
        ])
    }

    /// Erases a run of sectors, in 64 KB blocks where they're aligned.
    func erase(_ run: Range<Int>) throws(DownloadModeError) {
        var address = run.lowerBound
        while address < run.upperBound {
            let isBlock = address.isMultiple(of: 0x1_0000) && run.upperBound - address >= 0x1_0000
            _ = try Self.call(
                connection,
                isBlock ? ChipCommand.eraseBlock : ChipCommand.eraseSector,
                ChipCommand.bigEndian(UInt32(address), byteCount: 4)
            )
            address += isBlock ? 0x1_0000 : FlashPlan.sectorLength
        }
    }

    /// Programs erased flash, skipping chunks that stay erased.
    func program(_ bytes: [UInt8], at address: Int, _ chunkLength: Int) throws(DownloadModeError) {
        for start in stride(from: 0, to: bytes.count, by: chunkLength) {
            let chunk = Array(bytes[start..<min(start + chunkLength, bytes.count)])
            guard chunk.contains(where: { $0 != 0xFF }) else { continue }
            let command = ChipCommand.block(
                ChipCommand.writeFlash,
                ChipCommand.memoryWriteArguments(address: UInt32(address + start), block: chunk))
            _ = try Self.retrying { () throws(DownloadModeError) in try connection.execute(command, .send(chunk)) }
        }
    }

    /// The most the loader takes in one write, between 256 bytes and 4 KB; 512 if it doesn't say.
    func writeChunkLength() -> Int {
        guard let reply = try? Self.call(connection, ChipCommand.bufferSize) else { return 512 }
        return min(max(Int(ChipCommand.readBigEndian(reply, at: 2, byteCount: 4)), 256), 4096)
    }

    /// The plan's purpose as the FM-1's screen font can show it.
    static func screenTitle(_ purpose: FlashPlan.Purpose) -> String {
        switch purpose {
        case .restore: "RESTORE BACKUP"
        case .bootloader: "BOOTLOADER"
        case .firmware: "INSTALL FIRMWARE"
        }
    }
}

/// The FM-1's own screen while the flash loader runs, best effort: a problem showing something
/// never stops a write.
struct UnitScreen {
    /// Colours, RGB565.
    static let white: UInt16 = 0xFFFF
    static let amber: UInt16 = 0xFDA0
    static let mint: UInt16 = 0x7F57

    let session: FlashSession
    let isOn: Bool
    /// The percentage last shown, so the bar is sent only when it moves.
    private let shown = Box(-2)

    /// Switches the display on, only when the flash shows it's an FM-1's: the command drives the
    /// FM-1's display pins, which on another board are something else.
    init(session: FlashSession, isFM1: Bool) {
        self.session = session
        let reply = isFM1 ? Self.send(session, ChipCommand.displayOn, [1]) : nil
        isOn = reply?.count == 16 && reply?[2] == 1
    }

    /// Sends a display command once, without the retries flash commands get.
    private static func send(_ session: FlashSession, _ opcode: UInt16, _ arguments: [UInt8]) -> [UInt8]? {
        try? session.connection.execute(ChipCommand.block(opcode, arguments), .receive(16))
    }

    /// A row of text on the screen.
    struct Row {
        /// Which row, from 0 at the top.
        let row: Int
        /// Up to 20 characters: capitals, digits and a little punctuation.
        let text: String
        let colour: UInt16

        init(_ row: Int, _ text: String, colour: UInt16 = UnitScreen.white) {
            self.row = row
            self.text = text
            self.colour = colour
        }
    }

    /// Shows rows of text.
    func show(_ rows: [Row]) {
        guard isOn else { return }
        for row in rows {
            let bytes = Array(row.text.utf8.prefix(20))
            let arguments =
                [UInt8(row.row)] + ChipCommand.bigEndian(UInt32(row.colour), byteCount: 2)
                + ChipCommand.bigEndian(0, byteCount: 2) + ChipCommand.bigEndian(UInt32(bytes.count), byteCount: 2)
            _ = try? session.connection.execute(ChipCommand.block(ChipCommand.displayText, arguments), .send(bytes))
        }
    }

    /// Fills the progress bar to a percentage.
    func progress(_ percent: Int) {
        let percent = min(max(percent, 0), 100)
        guard isOn, percent - shown.value >= 2 || percent == 100 && shown.value != 100 else { return }
        shown.value = percent
        let arguments = [UInt8(percent)] + ChipCommand.bigEndian(UInt32(Self.mint), byteCount: 2)
        _ = Self.send(session, ChipCommand.displayBar, arguments)
    }

    /// A value the screen updates as it goes.
    private final class Box {
        var value: Int

        init(_ value: Int) {
            self.value = value
        }
    }
}
#endif
