public import Foundation

/// Why an update stopped.
///
/// Each error's `errorDescription` says what happened and what to do next, in words suitable
/// for showing to the person updating their FM-1.
public enum FM1UpdateError: Error, Hashable, LocalizedError {
    /// No port that looks like an FM-1 answered the handshake.
    case deviceNotFound
    /// More than one FM-1 answered, so the updater can't tell which to update.
    case multipleDevices(count: Int)
    /// The install would switch the FM-1 to a different firmware, which wasn't confirmed; see
    /// ``InstallOptions/confirmsSwitchingFirmware``.
    case switchNotConfirmed(device: String, package: String)
    /// The FM-1 is already running this firmware, and refuses to reinstall it.
    case alreadyInstalled(String)
    /// The FM-1's open firmware didn't report its update support, so the update didn't start.
    case capabilityUnavailable
    /// The FM-1's open firmware is busy with another update, so this one didn't start.
    case deviceBusy
    /// The FM-1's open firmware refused to arm for the package, with this code (`nil` when it
    /// didn't answer), so the update didn't start.
    case armRefused(code: Int?)
    /// The update finished, but the open firmware reports a different build from the package's.
    case buildMismatch(expected: FM1BuildID, reported: FM1BuildID)
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
    /// The device asked to finish the other half of the update during `phase`, so the update was
    /// stopped unanswered.
    case unexpectedFinish(phase: Phase)

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
        case .multipleDevices(let count):
            "\(count) FM-1s answered. Connect only the one to update, and try again."
        case .switchNotConfirmed(let device, let package):
            """
            Installing \(package) switches the FM-1 from \(device) to a different firmware, which can \
            erase its projects and samples. Back them up, then confirm the switch.
            """
        case .alreadyInstalled(let identity):
            "The FM-1 is already running \(identity), and refuses to reinstall it. Choose another firmware."
        case .capabilityUnavailable:
            """
            The FM-1's open firmware didn't say whether it's ready to update, so the update didn't start. \
            Switch it off and on again, and try again.
            """
        case .deviceBusy:
            """
            The FM-1's open firmware is busy with another update, so this one didn't start. Close any \
            other updater, switch the FM-1 off and on again, and try again.
            """
        case .armRefused(let code?):
            "The FM-1's open firmware refused this package (code \(code)), so the update didn't start."
        case .armRefused(nil):
            """
            The FM-1's open firmware didn't answer when asked to prepare for the update, so the update \
            didn't start. Switch it off and on again, and try again.
            """
        case .buildMismatch(let expected, let reported):
            """
            The update finished, but the FM-1 reports build \(reported.hex.prefix(16)) instead of \
            \(expected.hex.prefix(16)).
            """
        case .modelMismatch(let device, let package):
            "The device is \(device) but the package is for \(package)."
        case .stalled(.staging, let requests), .disconnected(.staging, let requests):
            """
            The FM-1 stopped after \(requests) requests while checking the package, before restarting \
            into its update loader. It should still start normally. If it doesn't, and its firmware \
            supports USB recovery mode (holding OCT− while switching it on), start it that way and \
            install again; otherwise recovering it needs a computer.
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
        case .unexpectedFinish(.staging):
            """
            The FM-1 asked to finish writing while it was still checking the package, so the update was \
            stopped. Switch it off and on again. If it starts in its update loader, resume the update; \
            otherwise install again.
            """
        case .unexpectedFinish(.writing):
            """
            The update loader asked to finish checking the package while it was writing, so the update \
            was stopped. Keep the FM-1 connected and resume the update; it stays in update mode until \
            one finishes.
            """
        }
    }
}
