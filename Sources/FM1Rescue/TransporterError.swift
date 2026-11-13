#if os(macOS)
public import Foundation

/// Why talking to the FM-1 Transporter stopped.
public enum TransporterError: Error, Hashable, LocalizedError {
    /// No FM-1 Transporter is connected.
    case notFound
    /// The serial port couldn't be opened or used: its path, and what went wrong.
    case portFailed(String, String)
    /// The Transporter didn't answer a request in time: the request.
    case noReply(String)
    /// The Transporter answered a request with something else: the request and the answer.
    case refused(String, String)
    /// The FM-1 didn't reach its boot ROM's download mode in time.
    case notInBootMode
    /// The flash loader isn't the `wl82loader.bin` the Transporter expects: its SHA-256.
    case wrongLoader(String)
    /// The Transporter's firmware takes only `wl82loader.bin`, not m-bootloader's flash loader.
    case loaderNotTaken
    /// The chip isn't an FM-1's: its chip key and flash ID.
    case notAnFM1(chipKey: UInt16, flashID: UInt32)
    /// A read didn't match the Transporter's CRC-32, or two reads didn't match each other.
    case readsDiffer
    /// The flash isn't the backup a write was planned against, so nothing was written.
    case flashChanged
    /// A plan writes a sector the Transporter refuses: the sector.
    case outsideWritableRange(Int)
    /// A sector wasn't written: its address and the Transporter's answer.
    case writeFailed(at: Int, String)
    /// The flash didn't read back as written: the first sector that differs.
    case writeNotVerified(Int)

    /// What happened and what to do next.
    public var errorDescription: String? {
        switch self {
        case .notFound:
            """
            No FM-1 Transporter was found. Connect it to the Mac, or name its data port with \
            --port.
            """
        case .portFailed(let path, let reason):
            "\(path) couldn't be used (\(reason)). Close any other app using it, such as Chrome."
        case .noReply(let request):
            "The Transporter didn't answer `\(request)`. Unplug it and plug it back in, then try again."
        case .refused(let request, let answer):
            "The Transporter answered `\(request)` with `\(answer)`."
        case .notInBootMode:
            """
            The FM-1 didn't reach boot mode. Switch it off, unplug the Transporter and plug it back \
            in, then try again and switch the FM-1 on when asked.
            """
        case .wrongLoader(let sha256):
            """
            This isn't jl-uboot-tool's wl82loader.bin (its SHA-256 is \(sha256)). Download it again \
            from the commit RECOVERY.md names.
            """
        case .loaderNotTaken:
            """
            This Transporter's firmware takes only jl-uboot-tool's wl82loader.bin. Name it with \
            --loader wl82loader.bin, or update the Transporter's firmware.
            """
        case .notAnFM1(let chipKey, let flashID):
            String(format: "The chip isn't an FM-1's: chip key 0x%04X, flash 0x%06X.", chipKey, flashID)
        case .readsDiffer:
            """
            Two reads of the flash didn't match, so the connection is unreliable and nothing was \
            saved or written. Check the wiring, then try again.
            """
        case .flashChanged:
            """
            The FM-1's flash isn't what the write was planned against, so nothing was written. Read \
            it again and plan the change again.
            """
        case .outsideWritableRange(let sector):
            String(
                format: """
                    The write reaches 0x%05X, outside the 0x04000–0x92FFF the Transporter writes, so \
                    nothing was written.
                    """, sector)
        case .writeFailed(let address, let answer):
            String(format: "Writing 0x%05X failed (", address)
                + """
                \(answer)). Don't switch the FM-1 off: check the wiring, then run the same command \
                again to finish.
                """
        case .writeNotVerified(let address):
            String(format: "0x%05X didn't read back as written. ", address)
                + "Don't switch the FM-1 off: run the same command again to write it once more."
        }
    }
}
#endif
