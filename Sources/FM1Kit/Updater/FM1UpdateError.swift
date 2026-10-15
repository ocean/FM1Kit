public import Foundation

/// Why an update stopped.
///
/// Each error's `errorDescription` says what happened and what to do next, in words suitable
/// for showing to the person updating their FM-1.
public enum FM1UpdateError: Error, Hashable, LocalizedError {
    /// No port that looks like an FM-1 answered the handshake.
    case deviceNotFound
    /// The device and the package are for different hardware.
    case modelMismatch(device: String, package: String)
    /// The device stopped asking for data during `phase`, after `requests` reads.
    case stalled(phase: Phase, requests: Int)
    /// The device disconnected during `phase`, after `requests` reads.
    case disconnected(phase: Phase, requests: Int)
    /// The update loader didn't appear, after staging or when resuming.
    case loaderNotFound
    /// The device didn't come back after its loader finished writing.
    case deviceDidNotReturn
    /// The device came back reporting a different identity from the package's.
    case identityMismatch(expected: String, reported: String)
    /// The device asked for a range outside the package, so the update was stopped unanswered.
    case badRequest(address: UInt32, length: Int)

    /// Which half of an update failed.
    ///
    /// A failure while staging leaves the device on its current firmware; one while writing
    /// leaves it waiting in its loader for ``FM1Updater/resume(_:events:)``.
    public enum Phase: String, Sendable, Hashable {
        /// The device checking the package before restarting into its loader.
        case staging
        /// The loader writing the package.
        case writing
    }

    /// What happened and what to do next.
    public var errorDescription: String? {
        switch self {
        case .deviceNotFound:
            "No FM-1 found. Check the cable, and close any other app using it."
        case .modelMismatch(let device, let package):
            "The device is \(device) but the package is for \(package)."
        case .stalled(.staging, let requests), .disconnected(.staging, let requests):
            """
            The FM-1 stopped after \(requests) requests while checking the package, before restarting \
            into its update loader. It should still start normally; if it doesn't, start it in USB \
            recovery mode and install again.
            """
        case .stalled(.writing, let requests):
            """
            The update loader stopped after \(requests) requests. Keep the FM-1 connected and resume \
            the update; it stays in update mode until one finishes.
            """
        case .disconnected(.writing, let requests):
            """
            The update loader disconnected after \(requests) requests. Reconnect the FM-1 and resume \
            the update; it stays in update mode until one finishes.
            """
        case .loaderNotFound:
            "The update loader didn't appear. Reconnect the FM-1 and resume the update."
        case .deviceDidNotReturn:
            "The FM-1 didn't come back after writing. Switch it off and on again."
        case .identityMismatch(let expected, let reported):
            "The update finished, but the FM-1 reports \(reported) instead of \(expected)."
        case .badRequest(let address, let length):
            """
            The FM-1 asked for data outside the package (\(length) bytes at 0x\(String(address, radix: 16))), \
            so the update was stopped without answering. Check the package is complete.
            """
        }
    }
}
