#if os(macOS)
public import FM1Kit

extension FM1Updater {
    /// The message that asks M-VAVE's V15, and Felucca, to restart into the chip's download mode.
    public static let downloadModeRequest: [UInt8] = [0xF0, 0x22, 0x24, 0x35, 0x7D, 0xF7]

    /// Asks the connected FM-1 to restart into the chip's USB download mode, then waits for it to
    /// appear there.
    ///
    /// M-VAVE's V15 and Felucca restart into download mode on this message, whichever bootloader
    /// is installed (m-bootloader's specification, §4.2); other firmwares may ignore it, and then
    /// holding REC while switching on, with m-bootloader, does the same. Nothing is written: the
    /// FM-1 stays in download mode until it's switched off and on, when it starts its firmware
    /// again. It's macOS-only: on an iPhone or iPad nothing could use download mode, and the FM-1
    /// would be left in it.
    ///
    /// - Parameter limit: How long to wait for download mode to appear.
    /// - Throws: ``FM1UpdateError/deviceNotFound`` or ``FM1UpdateError/multipleDevices(count:)``
    ///   when not exactly one FM-1 is running firmware; ``DownloadModeError/didNotEnterDownloadMode``
    ///   when it doesn't appear in download mode; or a ``MIDITransportError`` when sending fails.
    public func enterDownloadMode(waitingUpTo limit: Duration = .seconds(10)) async throws {
        let found = await findAll(where: { !$0.isLoader })
        defer {
            for device in found {
                device.connection.close()
            }
        }
        guard found.count <= 1 else { throw FM1UpdateError.multipleDevices(count: found.count) }
        guard let device = found.first else { throw FM1UpdateError.deviceNotFound }
        try device.connection.send(Self.downloadModeRequest)

        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(250))
            if USBDownloadModeConnection.deviceCount() > 0 { return }
        }
        throw DownloadModeError.didNotEnterDownloadMode
    }
}
#endif
