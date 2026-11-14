import FM1Kit
import FM1Rescue
import Foundation

// One case per command, so it is long; the longer commands live in their own files.
// swiftlint:disable cyclomatic_complexity function_body_length

/// Runs the command the arguments name, or prints the usage.
func runCommand() async throws {
    switch arguments.first {
    case "--version", "version":
        print("fm1probe \(fm1probeVersion)")

    case "licences", "licenses":
        print("fm1probe \(fm1probeVersion) is MIT-licensed: https://github.com/ocean/FM1Kit/blob/main/LICENSE")
        print("It contains code and files by others, under these terms:\n")
        print(ThirdPartyNotices.text)

    case "devices":
        try await listDevices()

    case "ports":
        let transport = try CoreMIDITransport(clientName: "fm1probe")
        let ports = await transport.ports()
        if ports.isEmpty { print("No MIDI port pairs found.") }
        for port in ports {
            print("\(FM1Updater.isProbeable(port) ? "probe" : "skip ")  \(portLabel(port))  [\(port.id)]")
        }

    case "identify":
        try await identify()

    case "monitor":
        let logPath = option("--log")
        let seconds = arguments.dropFirst().first { Int($0) != nil && $0 != logPath }.flatMap(Int.init) ?? 30
        try await monitor(seconds: seconds, logPath: logPath, showsHex: arguments.contains("--hex"))

    case "replay" where arguments.count >= 2:
        try replay(path: arguments[1], showsEveryMessage: arguments.contains("--all"))

    case "diff" where arguments.dropFirst().filter({ !$0.hasPrefix("--") }).count == 2:
        let files = arguments.dropFirst().filter { !$0.hasPrefix("--") }
        diff(files[0], files[1])

    case "simulate":
        let seconds = option("--seconds").flatMap(Int.init)
        let valued = Set(["--identity", "--flash-chip", "--seconds"].compactMap(option))
        let packagePath = arguments.dropFirst().first { !$0.hasPrefix("--") && !valued.contains($0) }
        try await simulate(packagePath: packagePath, seconds: seconds)

    case "watch":
        let transport = try CoreMIDITransport(clientName: "fm1probe")
        let seconds = arguments.dropFirst().first.flatMap(Int.init) ?? 60
        @Sendable func portSummary() async -> String {
            let names = await transport.ports().map { "\($0.name)\(FM1Updater.isProbeable($0) ? "" : " (skipped)")" }
            return names.isEmpty ? "no ports" : names.joined(separator: ", ")
        }
        print("Watching for \(seconds) s. Unplug and replug the FM-1, or switch it off and on.")
        let initial = await portSummary()
        print("\(timestamp())  \(initial)")
        let watching = Task {
            // CoreMIDI sends several notifications for one plug or unplug, so only print real changes.
            var shown = initial
            for await _ in transport.changes() {
                let summary = await portSummary()
                guard summary != shown else { continue }
                print("\(timestamp())  \(summary)")
                shown = summary
            }
        }
        try? await Task.sleep(for: .seconds(seconds))
        watching.cancel()
        print("Stopped watching after \(seconds) s.")

    case "inspect" where arguments.count >= 2:
        try inspect(path: arguments[1])

    case "check" where arguments.count >= 2:
        try checkPackage(arguments)

    case "restore-voices" where arguments.count >= 2:
        try await restoreVoices(
            path: arguments[1], isSimulated: arguments.contains("--simulated"), logPath: option("--log"))

    case "write-resources" where arguments.count >= 2:
        try await writeResources(
            path: arguments[1], isSimulated: arguments.contains("--simulated"), logPath: option("--log"))

    case "backup" where arguments.count >= 2:
        try await backUp(
            folderPath: arguments[1], isSimulated: arguments.contains("--simulated"), logPath: option("--log"))

    case "download-mode":
        try await enterDownloadMode()

    case "flash-backup" where arguments.count >= 2:
        try backUpFlash(
            folderPath: arguments[1],
            isSimulated: arguments.contains("--simulated"),
            traces: arguments.contains("--trace"))

    case "flash-restore", "flash-bootloader", "flash-install":
        try writeFlash(arguments)

    case "flash-image":
        try makeTransporterImage(arguments)

    case "transporter":
        try runTransporter(arguments)

    case "install-bootloader" where arguments.count >= 2:
        try await installBootloader(
            path: arguments[1],
            isSimulated: arguments.contains("--simulated"),
            fromAnyFirmware: arguments.contains("--from-any-firmware"),
            logPath: option("--log"))

    case "install" where arguments.count >= 2:
        let isResume = arguments.contains("--resume")
        let isSimulated = arguments.contains("--simulated")
        let reinstallsOfficial = arguments.contains("--reinstall-official")
        let path = arguments[1]
        let package = try FwscPackage(data: Data(contentsOf: URL(fileURLWithPath: path)))
        guard package.isFirmware else {
            print("\(path) installs a bootloader, not firmware. Use `fm1probe install-bootloader \(path)`.")
            exit(1)
        }
        let device: any MIDITransport
        if isSimulated {
            var options = SimulatedFM1.Options()
            options.startsInRecoveryMode = isResume
            let simulated = SimulatedFM1(options: options)
            simulated.prepare(for: package)
            device = simulated
        } else {
            device = try CoreMIDITransport(clientName: "fm1probe")
        }
        let logPath = option("--log")
        if let logPath, FileManager.default.fileExists(atPath: logPath) {
            print("\(logPath) already exists. Choose a new name for the log, so an earlier one isn't lost.")
            exit(1)
        }
        let transport: any MIDITransport =
            try logPath.map { LoggingTransport(device, log: try MessageLog(path: $0)) } ?? device
        let updater = await chosenUpdater(transport)
        var buildID: FM1BuildID?
        if let text = option("--build-id") {
            guard let id = FM1BuildID(hex: text) else {
                print("\(text) isn't a build ID: it should be 64 hex digits.")
                exit(1)
            }
            buildID = id
        }

        let official = OfficialFirmware.matching(package).map { "  (\($0.name), verified)" } ?? ""
        print("Package:  \(package.product)\(official)")
        guard let current = await updater.identify() else {
            print("No FM-1 answered. Check it's connected and switched on, then run `fm1probe ports`.")
            exit(1)
        }
        print("Device:   \(current.text)  (\(current.isLoader ? "update loader" : "firmware running"))")
        guard current.hardwareModel == package.identity.model else {
            print("The package is for \(package.identity.model), but the device is \(current.hardwareModel).")
            exit(1)
        }
        guard isResume == current.isLoader else {
            print(
                isResume
                    ? "The FM-1 isn't in its update loader, so there's no update to resume. Leave out --resume."
                    : "The FM-1 is waiting in its update loader. Run again with --resume to finish the update.")
            exit(1)
        }
        var switchWarning = ""
        if !isResume {
            let check: InstallCheck
            do {
                check = try await updater.check(package, buildID: buildID)
            } catch {
                print("Stopped: \(error.localizedDescription)")
                exit(1)
            }
            if let capability = check.capability {
                print("Open:     build \(capability.buildID.hex.prefix(16)), \(capability.isReady ? "ready" : "busy")")
            }
            switch check.kind {
            case .reinstall where check.canReinstallOfficial && reinstallsOfficial:
                print("Kind:     \(package.product) over an FM-1 reporting it too, as --reinstall-official allows")
            case .reinstall where check.canReinstallOfficial:
                print("The FM-1 reports \(package.product), so it isn't reinstalled. If it's running a firmware")
                print("that reports that identity, such as TransitFM1, run again with --reinstall-official.")
                exit(1)
            case .reinstall:
                print(
                    "The FM-1 is already running \(package.product), so it isn't reinstalled. Choose another package.")
                exit(1)
            case .sameIdentity:
                print("Kind:     the identity already running: a reinstall, or another release of it")
            case .update:
                print("Kind:     an update of the open firmware running")
            case .switchingFirmware:
                print("Kind:     switching to a different firmware")
                switchWarning = """

                    Switching firmware can erase the FM-1's projects and samples. Back them up first.
                    """
            }
        }

        if !isSimulated {
            print(
                """
                \(switchWarning)
                This writes \(package.product) to the FM-1. Keep the cable connected and the FM-1 switched on
                until it finishes. Its screen may stay dark while it writes: that's normal, so don't switch it
                off. If the cable comes out, plug it straight back in and finish with --resume. Ctrl-C stops
                the install:
                - while staging, the FM-1 should still start normally afterwards;
                - while writing, it waits in its update loader, as long as it stays switched on, for
                  `fm1probe install \(path) --resume`.

                """)
            print("Type YES to install it, or anything else to stop: ", terminator: "")
            guard readLine()?.trimmingCharacters(in: .whitespaces).uppercased() == "YES" else {
                print("Stopped. Nothing was sent apart from the handshake query.")
                exit(1)
            }
        }

        if let logPath { print("Logging every message to \(logPath).") }
        // Typing YES (or choosing a simulated run) confirms a switch of firmware or a same-identity install.
        let options = InstallOptions(
            confirmsSwitchingFirmware: true,
            confirmsSameIdentity: true,
            confirmsReinstallingOfficial: reinstallsOfficial,
            buildID: buildID
        )
        let report = InstallReport()
        let start = ContinuousClock.now
        let installation = Task {
            isResume
                ? try await updater.resume(package) { report.record($0) }
                : try await updater.install(package, options: options) { report.record($0) }
        }
        // Ctrl-C cancels the install, so the updater stops cleanly between requests.
        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        interrupt.setEventHandler { installation.cancel() }
        interrupt.resume()

        do {
            let installed = try await installation.value
            report.printSummary(total: ContinuousClock.now - start)
            print("\nInstalled: the FM-1 is running \(installed.text).")
        } catch is CancellationError {
            report.printSummary(total: ContinuousClock.now - start)
            switch report.step {
            case .writing, .checking:
                print("\nStopped while writing. Don't switch the FM-1 off; finish with --resume.")
            case .rebooting, .finished:
                print("\nStopped after writing. Check what the FM-1 is running with `fm1probe identify`.")
            case .starting, .staging, .waitingForLoader:
                print("\nStopped before writing. Check what the FM-1 is running with `fm1probe identify`.")
            }
            exit(1)
        } catch {
            report.printSummary(total: ContinuousClock.now - start)
            print("\nStopped: \(error.localizedDescription)")
            exit(1)
        }

    default:
        print(usage)
        exit(2)
    }
}

// swiftlint:enable cyclomatic_complexity function_body_length
