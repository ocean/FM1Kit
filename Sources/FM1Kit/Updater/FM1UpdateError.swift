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
    /// The FM-1 is already running this firmware, which isn't reinstalled.
    case alreadyInstalled(String)
    /// The package has the identity the FM-1's custom firmware reports, which wasn't confirmed;
    /// see ``InstallOptions/confirmsSameIdentity``.
    case sameIdentityNotConfirmed(String)
    /// The FM-1's open firmware didn't report its update support, so the update didn't start.
    case capabilityUnavailable
    /// The FM-1's open firmware is busy with another update, so this one didn't start.
    case deviceBusy
    /// The FM-1's open firmware refused to arm for the package, with this code (`nil` when it
    /// didn't answer), so the update didn't start.
    case armRefused(code: Int?)
    /// The update finished, but the open firmware reports a different build from the package's.
    case buildMismatch(expected: FM1BuildID, reported: FM1BuildID)
    /// The package isn't M-VAVE's official V15, so it has no factory voices to restore.
    case factoryVoicesUnavailable
    /// Restoring the factory voices needs the FM-1 running V15, but it reports this.
    case voiceRestoreNeedsV15(device: String)
    /// V15 refused a step of the voice restore with this code, after `bytesWritten` of the voices.
    case voiceRestoreRefused(code: Int, bytesWritten: Int)
    /// V15 stopped answering during the voice restore, after `bytesWritten` of the voices.
    case voiceRestoreStalled(bytesWritten: Int)
    /// Backups need the FM-1 running M-VAVE's open firmware, but it reports this.
    case backupNeedsOpenFirmware(device: String)
    /// The FM-1's open firmware didn't answer as its project library should.
    case projectLibraryUnavailable
    /// The FM-1's sample bank is being written or checked, so it can't be read yet.
    case sampleBankBusy
    /// The FM-1's open firmware refused a backup request with this status.
    case backupRefused(code: Int)
    /// The FM-1's open firmware stopped answering during a backup.
    case backupStalled
    /// The device and the package are for different hardware.
    case modelMismatch(device: String, package: String)
    /// The package brings an installer rather than firmware, so it can't be installed as one;
    /// see ``BootloaderInstaller``.
    case notFirmware(String)
    /// Installing m-bootloader needs the FM-1 running V15, the only firmware it has been
    /// installed from so far, but it reports this.
    case bootloaderInstallNeedsV15(device: String)
    /// The FM-1 took the bootloader installer but didn't restart to run it.
    case installerDidNotStart
    /// The firmware stopped while comparing the package's bootloader with the FM-1's, after
    /// `requests` reads: firmwares with Felucca's original update check accept a package with
    /// M-VAVE's update loader (V15, open firmware) only when the FM-1 already has the bootloader
    /// it brings, so they refuse V15 once the FM-1's bootloader has been changed (by m-bootloader,
    /// or by M-VAVE's open firmware).
    case bootloaderMismatch(requests: Int)
    /// The firmware read the package's header and stopped, after `requests` reads: it refused the
    /// package. Firmwares with Felucca's original update check do this for m-bootloader's
    /// installer and for update loaders they don't recognise, and those based on Felucca 1.6.1
    /// for M-VAVE's open firmware too.
    case packageRefused(requests: Int)
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
            "The FM-1 is already running \(identity), so it isn't reinstalled. Choose another firmware."
        case .sameIdentityNotConfirmed(let identity):
            """
            The FM-1 already reports \(identity), the same identity as this package. Confirm you mean to \
            reinstall it, or to install another release of the same firmware.
            """
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
        case .factoryVoicesUnavailable:
            "This package isn't M-VAVE's official V15, so it can't restore the factory voices."
        case .voiceRestoreNeedsV15(let device):
            "Restoring the factory voices needs the FM-1 running V15 (FM-1_015), but it reports \(device)."
        case .voiceRestoreRefused(let code, let written):
            """
            The FM-1 refused to restore the factory voices (code \(code)) after \(written) of 16384 bytes. \
            Some voices may be wrong or silent until a restore finishes: keep the FM-1 on V15 and try again.
            """
        case .voiceRestoreStalled(let written):
            """
            The FM-1 stopped answering while restoring the factory voices, after \(written) of 16384 bytes. \
            Some voices may be wrong or silent until a restore finishes: reconnect the FM-1, keep it on V15, \
            and run the restore again.
            """
        case .backupNeedsOpenFirmware(let device):
            """
            Only M-VAVE's open firmware can be backed up, but the FM-1 reports \(device). Other \
            firmwares have no known way to read their projects or samples.
            """
        case .projectLibraryUnavailable:
            """
            The FM-1's open firmware didn't answer as expected, so it couldn't be backed up. Check \
            the cable and that no other app is using the FM-1, then try again.
            """
        case .sampleBankBusy:
            "The FM-1 is still storing its sample bank. Wait until it finishes, then try again."
        case .backupRefused(let code):
            """
            The FM-1 refused part of the backup (status \(code)). If it's showing a different \
            project, load yours again; its saved slots haven't changed.
            """
        case .backupStalled:
            """
            The FM-1 stopped answering during the backup. Reconnect it and try again. If it's \
            showing a different project, load yours again: its saved slots haven't changed, but \
            unsaved changes may be lost.
            """
        case .modelMismatch(let device, let package):
            "The device is \(device) but the package is for \(package)."
        case .notFirmware(let product):
            "\(product) installs a bootloader, not firmware, so it can't be installed as firmware."
        case .bootloaderInstallNeedsV15(let device):
            """
            Installing m-bootloader needs the FM-1 running M-VAVE's V15 (FM-1_015), but it reports \
            \(device). Install V15 first, then the bootloader.
            """
        case .installerDidNotStart:
            """
            The FM-1 took the bootloader installer but didn't restart to run it, so the bootloader \
            wasn't installed. Switch the FM-1 off and on again; it should start normally.
            """
        case .bootloaderMismatch(let requests):
            """
            The FM-1's firmware stopped after \(requests) requests, while comparing this package's \
            bootloader with the FM-1's, and should carry on as before. Firmwares with Felucca's \
            original update check, such as AMB-1, HYP-1, DUB-1 and Felucca itself, install M-VAVE's \
            packages only when the FM-1 already has the bootloader the package brings, so they \
            refuse V15 once the FM-1's bootloader has been changed, by m-bootloader or by M-VAVE's \
            open firmware. Install it from a Mac in the chip's USB download mode instead, which \
            keeps the FM-1's bootloader, or first install a firmware with Felucca's updated check, \
            such as LOOM-8, which takes it.
            """
        case .packageRefused(let requests):
            """
            The FM-1's firmware read this package's header and stopped after \(requests) requests: \
            it refused the package, and should carry on as before. Its screen may show FAILED and a \
            code. Firmwares with Felucca's original update check refuse m-bootloader's installer and \
            update loaders they don't recognise this way, and those based on Felucca 1.6.1 refuse \
            M-VAVE's open firmware too. Install it from a Mac in the chip's USB download mode \
            instead, or first install a firmware with Felucca's updated check, such as LOOM-8, which \
            takes it.
            """
        case .stalled(.staging, let requests), .disconnected(.staging, let requests):
            """
            The FM-1 stopped after \(requests) requests while checking the package, before restarting \
            into its update loader. It should still start normally. If its screen shows an update \
            error of its own, its firmware refused this package: some custom firmwares bring their \
            own update code and accept only certain packages. Replacing such a firmware needs the \
            chip's USB download mode and a tool that writes there, such as M-Flasher; the \
            firmware's instructions say how to start download mode. If the FM-1 doesn't start, and \
            its firmware supports USB recovery mode (holding OCT− while switching it on), start it \
            that way and install again; otherwise recovering it needs a computer.
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
