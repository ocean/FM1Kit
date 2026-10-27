import Foundation
import Testing
import os

@_spi(Testing) @testable import FM1Kit

/// The plain-language layer apps build on: advice for errors, one progress bar, and a summary
/// of the connected FM-1.
struct FriendlyAPITests {
    // MARK: - Advice.

    @Test func advisesResumingAnInterruptedWrite() {
        let advice = FM1Advice(for: FM1UpdateError.disconnected(phase: .writing, requests: 312))
        #expect(advice.headline == "The install was interrupted")
        #expect(!advice.isDeviceFine)
        #expect(advice.action == .resume)
        #expect(advice.explanation.contains("resume"))
        #expect(advice.technicalDetails.contains("312"))
    }

    @Test func advisesTryingAgainWhenStagingStops() {
        let advice = FM1UpdateError.stalled(phase: .staging, requests: 3).advice
        #expect(advice.isDeviceFine)
        #expect(advice.action == .tryAgain)
    }

    @Test func advisesOnPackagesConnectionsAndCancelling() {
        #expect(FM1Advice(for: FwscPackage.Failure.damagedHeader).action == .chooseAnotherFirmware)
        #expect(FM1Advice(for: MIDITransportError.portGone).action == .reconnect)
        #expect(FM1Advice(for: CancellationError()).action == .dismiss)
        #expect(FM1Advice(for: URLError(.timedOut)).action == .tryAgain)
    }

    @Test func everyErrorHasAHeadlineAndAnExplanation() {
        let errors: [FM1UpdateError] = [
            .deviceNotFound, .multipleDevices(count: 2), .switchNotConfirmed(device: "a", package: "b"),
            .alreadyInstalled("a"), .sameIdentityNotConfirmed("a"), .capabilityUnavailable, .deviceBusy,
            .armRefused(code: 3), .armRefused(code: nil), .factoryVoicesUnavailable,
            .voiceRestoreNeedsV15(device: "a"), .voiceRestoreRefused(code: 1, bytesWritten: 0),
            .voiceRestoreStalled(bytesWritten: 0), .backupNeedsOpenFirmware(device: "a"),
            .projectLibraryUnavailable, .sampleBankBusy, .backupRefused(code: 71), .backupStalled,
            .modelMismatch(device: "a", package: "b"), .notFirmware("a"), .bootloaderInstallNeedsV15(device: "a"),
            .installerDidNotStart,
            .bootloaderMismatch(requests: 4), .packageRefused(requests: 2), .loaderNotFound, .deviceDidNotReturn,
            .identityMismatch(expected: "a", reported: "b"), .badRequest(address: 0, length: 1),
            .unexpectedFinish(phase: .staging), .unexpectedFinish(phase: .writing),
        ]
        for error in errors {
            #expect(!error.advice.headline.isEmpty)
            #expect(!error.advice.explanation.isEmpty)
        }
    }

    // MARK: - Progress.

    @Test func foldsAnInstallIntoOneBarThatNeverGoesBack() async throws {
        var options = UpdaterTests.fastOptions
        options.checksAfterWriting = true
        let device = SimulatedFM1(options: options)
        let package = try UpdaterTests.package()
        device.prepare(for: package)
        let events = OSAllocatedUnfairLock(initialState: [UpdateEvent]())
        let updater = FM1Updater(transport: device, timing: UpdaterTests.fastTiming)
        try await updater.install(package, options: .confirmed) { event in events.withLock { $0.append(event) } }

        var progress = InstallProgress()
        var fractions: [Double] = []
        var stages: [InstallProgress.Stage] = []
        for event in events.withLock({ $0 }) {
            progress.record(event)
            fractions.append(progress.fraction)
            if stages.last != progress.stage { stages.append(progress.stage) }
        }
        #expect(fractions == fractions.sorted())
        #expect(progress.fraction == 1)
        #expect(progress.isFinished)
        #expect(stages == [.gettingReady, .restarting, .installing, .checking, .restarting])
    }

    @Test func stagingApproachesItsShareWithoutReachingIt() {
        var progress = InstallProgress()
        progress.record(.staging(requests: 10_000))
        #expect(progress.fraction < InstallProgress.stagingShare)
        #expect(progress.fraction > InstallProgress.stagingShare * 0.9)
        #expect(progress.stage.title == "Getting ready")
    }

    // MARK: - Summary.

    @Test func summarisesV15WithItsSerialNumber() async throws {
        var options = UpdaterTests.fastOptions
        options.installedIdentity = .officialV15
        options.serialNumber = "4150353835313708"
        let summary = try #require(
            try await FM1Updater(transport: SimulatedFM1(options: options), timing: UpdaterTests.fastTiming).summary())
        #expect(summary.firmwareName == "M-VAVE V15")
        #expect(summary.firmwareVersion == "15")
        #expect(summary.serialNumber == "4150353835313708")
        #expect(summary.portName == SimulatedFM1.portName)
        #expect(!summary.isWaitingMidUpdate)
    }

    @Test func namesOpenFirmwareAndLeavesOthersToTheApp() throws {
        let open = FM1DeviceSummary(
            identity: FM1Identity(model: "FM-1", version: 8_000_012), portName: "", serialNumber: nil)
        #expect(open.firmwareName == "M-VAVE open firmware")
        #expect(open.firmwareVersion == "12")
        let felucca = FM1DeviceSummary(
            identity: FM1Identity(model: "FM-1", version: 916), portName: "", serialNumber: nil)
        #expect(felucca.firmwareName == nil)
        #expect(felucca.firmwareVersion == nil)
        let loader = FM1DeviceSummary(
            identity: FM1Identity(model: "ota-FM-1", version: 15), portName: "", serialNumber: nil)
        #expect(loader.isWaitingMidUpdate)
        #expect(loader.firmwareName == nil)
    }

    @Test func summarisesNothingWhenNoFM1Answers() async throws {
        #expect(try await FM1Updater(transport: EmptyTransport(), timing: UpdaterTests.fastTiming).summary() == nil)
    }
}

/// A transport with no ports.
private final class EmptyTransport: MIDITransport {
    func ports() async -> [MIDIPortDescriptor] { [] }
    func open(_: MIDIPortDescriptor) async throws -> any MIDIConnection { throw MIDITransportError.portGone }
    func changes() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}
