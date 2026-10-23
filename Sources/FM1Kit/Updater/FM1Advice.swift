import Foundation

/// What an error means for the person holding the FM-1: a short headline, whether the FM-1 is
/// still fine as it is, and the one thing to do next.
///
/// Apps can build a whole problem screen from it: ``headline`` as the title, ``explanation`` as
/// the text, a button for ``action``, and ``technicalDetails`` behind a disclosure, ready to copy
/// into a bug report.
///
/// ```swift
/// } catch {
///     let advice = FM1Advice(for: error)
///     showProblem(advice.headline, advice.explanation, button: advice.action)
/// }
/// ```
public struct FM1Advice: Sendable, Hashable {
    /// The one thing to do next.
    public enum Action: Sendable, Hashable {
        /// Try the same thing again.
        case tryAgain
        /// Finish the interrupted update with ``FM1Updater/resume(_:events:)``.
        case resume
        /// Unplug the FM-1, plug it back in, and try again.
        case reconnect
        /// Switch the FM-1 off and on again, then try again.
        case switchOffAndOn
        /// Ask the person to confirm, then try again with the confirmation.
        case confirm
        /// Choose a different firmware or file.
        case chooseAnotherFirmware
        /// Switch the FM-1 off, then hold these keys while switching it on.
        case holdKeysAtPowerOn([FM1Key])
        /// This needs a computer: the FM-1's download mode, with a tool such as M-Flasher.
        case needsComputer
        /// Nothing can be done from here; just acknowledge it.
        case dismiss
    }

    /// A short, plain headline, such as "The install was interrupted".
    public let headline: String
    /// What happened and what to do, in a sentence or three.
    public let explanation: String
    /// True when the FM-1 should still work as it did before; false when it's waiting part-way
    /// through an update, or may be left changed.
    public let isDeviceFine: Bool
    /// The one thing to do next.
    public let action: Action
    /// The error as the code sees it, for a details view or a bug report.
    public let technicalDetails: String

    /// Advice for any error FM1Kit throws, or general advice for any other error.
    ///
    /// - Parameter error: An ``FM1UpdateError``, ``FwscPackage/Failure``,
    ///   ``MIDITransportError``, `CancellationError` or anything else.
    public init(for error: any Error) {
        let details = String(reflecting: error)
        switch error {
        case let error as FM1UpdateError:
            self = error.advice
        case let error as FwscPackage.Failure:
            self.init(
                headline: "This file can't be installed",
                explanation: error.errorDescription ?? "",
                isDeviceFine: true,
                action: .chooseAnotherFirmware,
                technicalDetails: details
            )
        case let error as MIDITransportError:
            self.init(
                headline: "The FM-1 couldn't be reached",
                explanation: (error.errorDescription ?? "")
                    + " Check the cable, and close any other app using the FM-1.",
                isDeviceFine: true,
                action: .reconnect,
                technicalDetails: details
            )
        case is CancellationError:
            self.init(
                headline: "Stopped",
                explanation: "It was stopped before it finished.",
                isDeviceFine: true,
                action: .dismiss,
                technicalDetails: details
            )
        default:
            self.init(
                headline: "Something went wrong",
                explanation: error.localizedDescription,
                isDeviceFine: true,
                action: .tryAgain,
                technicalDetails: details
            )
        }
    }

    /// Makes advice from its parts, for errors FM1Kit doesn't know about.
    ///
    /// - Parameters:
    ///   - headline: A short, plain headline.
    ///   - explanation: What happened and what to do.
    ///   - isDeviceFine: Whether the FM-1 should still work as it did before.
    ///   - action: The one thing to do next.
    ///   - technicalDetails: The error as the code sees it.
    public init(headline: String, explanation: String, isDeviceFine: Bool, action: Action, technicalDetails: String) {
        self.headline = headline
        self.explanation = explanation
        self.isDeviceFine = isDeviceFine
        self.action = action
        self.technicalDetails = technicalDetails
    }
}

/// An FM-1 key that some firmwares and bootloaders check while the FM-1 switches on.
public enum FM1Key: String, Sendable, Hashable, CaseIterable {
    /// OCT−: USB recovery mode, in firmwares that offer it.
    case octaveDown = "OCT−"
    /// PLAY: m-bootloader's recovery menu.
    case play = "PLAY"
    /// REC: m-bootloader's download mode.
    case record = "REC"
}

extension FM1UpdateError {
    /// What this error means for the person holding the FM-1, and what to do next.
    public var advice: FM1Advice {
        let (headline, action) = summary
        return FM1Advice(
            headline: headline,
            explanation: errorDescription ?? "",
            isDeviceFine: !mayLeaveDeviceChanged,
            action: action,
            technicalDetails: String(reflecting: self)
        )
    }

    /// True when the FM-1 may be left waiting part-way through an update, or otherwise changed.
    private var mayLeaveDeviceChanged: Bool {
        switch self {
        case .voiceRestoreRefused, .voiceRestoreStalled, .backupRefused, .backupStalled,
            .stalled(.writing, _), .disconnected(.writing, _), .loaderNotFound, .unexpectedFinish,
            .deviceDidNotReturn, .badRequest:
            true
        default:
            false
        }
    }

    /// The headline and the action.
    private var summary: (String, FM1Advice.Action) {
        switch self {
        case .deviceNotFound: ("No FM-1 found", .reconnect)
        case .multipleDevices: ("More than one FM-1 is connected", .reconnect)
        case .switchNotConfirmed: ("This switches to a different firmware", .confirm)
        case .alreadyInstalled: ("This firmware is already installed", .chooseAnotherFirmware)
        case .sameIdentityNotConfirmed: ("This firmware looks already installed", .confirm)
        case .capabilityUnavailable, .deviceBusy, .armRefused(nil):
            ("The FM-1 wasn't ready to update", .switchOffAndOn)
        case .armRefused: ("The FM-1 refused this firmware", .chooseAnotherFirmware)
        case .buildMismatch, .identityMismatch: ("The FM-1 is running something else", .tryAgain)
        case .factoryVoicesUnavailable: ("This file has no factory voices", .chooseAnotherFirmware)
        case .voiceRestoreNeedsV15: ("The factory voices need V15", .chooseAnotherFirmware)
        case .voiceRestoreRefused: ("The voices weren't all restored", .tryAgain)
        case .voiceRestoreStalled: ("The voices weren't all restored", .reconnect)
        case .backupNeedsOpenFirmware: ("This firmware can't be backed up", .dismiss)
        case .projectLibraryUnavailable: ("The backup couldn't start", .reconnect)
        case .sampleBankBusy: ("The FM-1 is still busy", .tryAgain)
        case .backupRefused: ("The backup stopped part-way", .tryAgain)
        case .backupStalled: ("The backup stopped part-way", .reconnect)
        case .modelMismatch: ("This firmware isn't for the FM-1", .chooseAnotherFirmware)
        case .notFirmware: ("This file isn't a firmware", .chooseAnotherFirmware)
        case .bootloaderInstallNeedsV15: ("The bootloader needs V15 first", .chooseAnotherFirmware)
        case .installerDidNotStart: ("The bootloader wasn't installed", .switchOffAndOn)
        case .stalled(.staging, _), .disconnected(.staging, _): ("The install didn't start", .tryAgain)
        case .stalled(.writing, _), .disconnected(.writing, _), .loaderNotFound, .unexpectedFinish(.writing):
            ("The install was interrupted", .resume)
        case .deviceDidNotReturn: ("The FM-1 didn't come back", .switchOffAndOn)
        case .badRequest: ("The firmware file looks damaged", .chooseAnotherFirmware)
        case .unexpectedFinish(.staging): ("The install stopped", .switchOffAndOn)
        }
    }
}
