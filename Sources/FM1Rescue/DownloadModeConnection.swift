#if os(macOS)
public import Foundation

/// A connection to an FM-1 in the chip's USB download mode, which carries 16-byte commands
/// with a data phase in one direction, as a USB disk does.
///
/// In download mode the FM-1's chip shows up as a USB disk (`WL82 UBOOT1.00`, USB `4C4A:8057`)
/// that takes the chip's own commands. ``USBDownloadModeConnection`` reaches a real one; tests
/// and previews use ``SimulatedDownloadMode``.
public protocol DownloadModeConnection: AnyObject {
    /// Sends one command and runs its data phase.
    ///
    /// - Parameters:
    ///   - command: The command block: 6 bytes for a standard disk command, 16 for the chip's own.
    ///   - phase: Which way data moves after the command, if at all.
    /// - Returns: The bytes received, which can be fewer than asked for; empty unless `phase`
    ///   receives.
    /// - Throws: ``DownloadModeError/commandFailed(_:)`` when the device reports the command
    ///   failed, or ``DownloadModeError/transferFailed(_:)`` when the transfer itself does.
    func execute(_ command: [UInt8], _ phase: DataPhase) throws(DownloadModeError) -> [UInt8]

    /// Lets go of the device. It stays in download mode until it's switched off.
    func close()
}

/// Which way a command's data moves.
public enum DataPhase: Sendable, Hashable {
    /// No data.
    case noData
    /// Receive up to this many bytes from the device.
    case receive(Int)
    /// Send these bytes to the device.
    case send([UInt8])
}

/// Why download mode couldn't be reached or used.
///
/// Each error's `errorDescription` says what happened and what to do next.
public enum DownloadModeError: Error, Hashable, LocalizedError {
    /// No FM-1 in download mode is connected.
    case notFound
    /// More than one device in download mode is connected.
    case multipleDevices(count: Int)
    /// Taking the FM-1 from macOS's disk driver needs root.
    case needsRoot
    /// macOS didn't let FM1Kit take the FM-1; the text says what it reported.
    case accessRefused(String)
    /// The device answered as something other than the chip's download mode.
    case notDownloadMode(String)
    /// Another flash loader (JieLi's, from another tool) is already running on the chip.
    case otherLoaderRunning
    /// The flash loader didn't start after it was uploaded.
    case loaderDidNotStart
    /// The device reported that a command failed; the text names it.
    case commandFailed(String)
    /// A transfer to or from the device failed; the text says which.
    case transferFailed(String)
    /// The flash isn't the 1 MB the FM-1 has; this is the size the chip reports, in bytes.
    case unexpectedFlashSize(Int)
    /// Two reads of the flash, or a read and the chip's own checksum, didn't match.
    case readsDiffer
    /// The FM-1 didn't switch into download mode after it was asked to.
    case didNotEnterDownloadMode
    /// The flash isn't what a plan was made against, or it's another FM-1, so nothing was written.
    case flashChanged
    /// A run of sectors didn't read back as written, twice; these are its addresses.
    case writeNotVerified(Range<Int>)
    /// The device stopped answering after writing started: the address being written, and what
    /// went wrong.
    case writeInterrupted(at: Int, String)

    /// What happened and what to do next.
    public var errorDescription: String? {
        switch self {
        case .notFound:
            """
            No FM-1 in download mode was found. With m-bootloader, hold REC while switching the FM-1 \
            on; with V15 or Felucca running, FM1Kit can ask it to switch.
            """
        case .multipleDevices(let count):
            "\(count) devices are in download mode. Connect only the FM-1 to back up."
        case .needsRoot:
            "Taking the FM-1 from macOS's disk driver needs administrator rights: run this with sudo."
        case .accessRefused(let reason):
            """
            macOS didn't let FM1Kit use the FM-1 (\(reason)). It asks once to allow access to a \
            removable volume: if that was refused, allow it in System Settings › Privacy & Security \
            › Files & Folders, then switch the FM-1 off and on in download mode and try again.
            """
        case .notDownloadMode(let answer):
            "The device answered as \(answer), not the FM-1's download mode."
        case .otherLoaderRunning:
            """
            Another tool's flash loader is running on the FM-1. Switch it off and on in download \
            mode, then try again.
            """
        case .loaderDidNotStart:
            """
            The flash loader didn't start. Switch the FM-1 off and on in download mode, then try \
            again.
            """
        case .commandFailed(let command):
            "The FM-1 refused \(command). Switch it off and on in download mode, then try again."
        case .transferFailed(let detail):
            """
            The USB connection failed (\(detail)). Try another cable or port, without a hub, then \
            switch the FM-1 off and on in download mode and try again.
            """
        case .unexpectedFlashSize(let size):
            "The chip reports \(size) bytes of flash, not the FM-1's 1 MB, so it wasn't read."
        case .readsDiffer:
            """
            Two reads of the flash didn't match, so the USB connection is unreliable and no backup \
            was saved. Try another cable or port, without a hub.
            """
        case .didNotEnterDownloadMode:
            """
            The FM-1 didn't switch into download mode. Its firmware may not support it: with \
            m-bootloader, hold REC while switching it on instead.
            """
        case .flashChanged:
            """
            The FM-1's flash has changed since it was read, or another FM-1 is connected, so nothing \
            was written. Read it again and plan the change again.
            """
        case .writeNotVerified(let run):
            String(format: "0x%05X–0x%05X", run.lowerBound, run.upperBound - 1)
                + """
                 didn't read back as written, after two tries. Don't switch the FM-1 off: restore the \
                backup saved before writing, with another cable or port and without a hub.
                """
        case .writeInterrupted(let address, let detail):
            String(format: "Writing stopped at 0x%05X", address)
                + """
                 (\(detail)). Don't switch the FM-1 off: reconnect it, with another cable or port and \
                without a hub, and restore the backup saved before writing.
                """
        }
    }
}
#endif
