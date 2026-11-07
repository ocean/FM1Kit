#if os(macOS)
import Foundation

extension USBDownloadModeConnection {
    /// Waits for a device to appear in download mode, then captures it at once.
    ///
    /// For an FM-1 that only passes through download mode. A firmware that crashes at start-up
    /// can bring the chip into download mode by itself after failed starts, and the chip can
    /// restart into the crash a few seconds later if nothing takes it. This looks every 20 ms
    /// and captures the device as soon as it appears; if capturing fails, as it can when the chip
    /// restarts part-way, it waits for the next time. Once captured, the device stays in download
    /// mode until the connection closes.
    ///
    /// - Parameter limit: How long to wait altogether.
    /// - Returns: The open connection; close it when finished.
    /// - Throws: ``DownloadModeError/needsRoot`` at once when not run as root,
    ///   ``DownloadModeError/multipleDevices(count:)`` when more than one device is in download
    ///   mode, or, when the time runs out, ``DownloadModeError/notFound`` if none appeared, or
    ///   the last error from capturing one that did.
    public static func open(waitingUpTo limit: Duration) throws(DownloadModeError) -> USBDownloadModeConnection {
        guard geteuid() == 0 else { throw .needsRoot }
        let deadline = ContinuousClock.now + limit
        var lastError = DownloadModeError.notFound
        while true {
            var pause = 0.02
            do {
                return try open()
            } catch .notFound {
                // Not there yet: look again shortly.
            } catch .multipleDevices(let count) {
                throw .multipleDevices(count: count)
            } catch {
                lastError = error
                // Give a chip that restarted part-way time to leave before looking again.
                pause = 1
            }
            guard ContinuousClock.now < deadline else { throw lastError }
            Thread.sleep(forTimeInterval: pause)
        }
    }
}
#endif
