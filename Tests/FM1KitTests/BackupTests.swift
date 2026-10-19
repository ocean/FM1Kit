import Foundation
import Testing
import os

@_spi(Testing) @testable import FM1Kit

/// Backing up open firmware through its project library.
struct BackupTests {
    static let openV12 = FM1Identity(model: "FM-1", version: 8_000_012)
    static let samples = (0..<1000).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 7) }

    static func device(_ change: (inout SimulatedFM1.Options) -> Void = { _ in }) -> SimulatedFM1 {
        var options = UpdaterTests.fastOptions
        options.installedIdentity = openV12
        options.projectSlots = [
            0: SimulatedFM1.ProjectSlot(name: "GROOVE", project: .sample(seed: 1)),
            3: SimulatedFM1.ProjectSlot(name: "ACID LINE", project: .sample(seed: 4)),
        ]
        options.workspace = .sample(seed: 1)
        options.currentSlot = 0
        options.sampleBank = samples
        change(&options)
        return SimulatedFM1(options: options)
    }

    static var timing: UpdaterTiming {
        var timing = UpdaterTests.fastTiming
        timing.libraryReplyWait = .milliseconds(100)
        return timing
    }

    static func backUp(_ device: SimulatedFM1) async throws -> OpenFirmwareBackup {
        try await FM1Updater(transport: device, timing: timing).backUpOpenFirmware()
    }

    @Test func framesRequestsAsOpenFirmwareExpects() throws {
        // 7D 46 4D 02 00 01 00 sum to 275; 109 makes it a multiple of 128.
        #expect(ProjectLibraryMessage.request(.info, token: 1) == [0xF0, 0x7D, 0x46, 0x4D, 0x02, 0, 1, 0, 109, 0xF7])
        let message = ProjectLibraryMessage.request(.read, token: 300, payload: [0x40, 0x0F, 64])
        let parsed = try #require(ProjectLibraryMessage.parse(message))
        #expect(parsed.command == 2)
        #expect(parsed.token == 300)
        #expect(parsed.payload == [0x40, 0x0F, 64])
    }

    @Test func rejectsABadChecksum() {
        var message = ProjectLibraryMessage.request(.info, token: 1)
        message[8] ^= 1
        #expect(ProjectLibraryMessage.parse(message) == nil)
    }

    @Test func checksumsAsZlibDoes() {
        #expect(CRC32.checksum(Array("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test func projectFilesRoundTrip() throws {
        let project = OpenFirmwareProject.sample(seed: 9)
        let file = project.fileData()
        #expect(file.count == 16 + 4064)
        #expect(Array(file.prefix(8)) == Array("FM1P".utf8) + [4, 0, 0, 0])
        #expect(OpenFirmwareProject(fileData: file) == project)

        var damaged = file
        damaged[100] ^= 1
        #expect(OpenFirmwareProject(fileData: damaged) == nil)
    }

    @Test func projectsNeedAKnownLengthAndVersion() {
        #expect(OpenFirmwareProject(bytes: [UInt8](repeating: 4, count: 4000)) == nil)
        var bytes = OpenFirmwareProject.sample(seed: 2).bytes
        bytes[OpenFirmwareProject.versionOffset] = 3
        #expect(OpenFirmwareProject(bytes: bytes) == nil)
    }

    @Test func readsEverySlotTheWorkspaceAndTheSamples() async throws {
        let device = Self.device()
        let fractions = OSAllocatedUnfairLock(initialState: [Double]())
        let backup = try await FM1Updater(transport: device, timing: Self.timing).backUpOpenFirmware { fraction in
            fractions.withLock { $0.append(fraction) }
        }
        #expect(backup.identity == Self.openV12)
        #expect(backup.currentSlot == 0)
        #expect(backup.workspace == .sample(seed: 1))
        #expect(backup.slots.count == 16)
        #expect(backup.slots[0].name == "GROOVE")
        #expect(backup.slots[0].project == .sample(seed: 1))
        #expect(backup.slots[3].name == "ACID LINE")
        #expect(backup.slots[3].project == .sample(seed: 4))
        #expect(backup.slots.filter { $0.project == nil }.count == 14)
        #expect(backup.samples == Data(Self.samples))

        let reported = fractions.withLock { $0 }
        #expect(reported.first == 0)
        #expect(reported.last == 1)
        #expect(reported == reported.sorted())
    }

    @Test func leavesACleanWorkspaceOnItsSlot() async throws {
        let device = Self.device()
        _ = try await Self.backUp(device)
        #expect(device.currentSlot == 0)
        #expect(device.currentWorkspace == .sample(seed: 1))
        #expect(!device.hasUnsavedChanges)
    }

    @Test func putsBackUnsavedChanges() async throws {
        let edited = OpenFirmwareProject.sample(seed: 50)
        let device = Self.device { $0.workspace = edited }
        let backup = try await Self.backUp(device)
        #expect(backup.workspace == edited)
        #expect(device.currentSlot == 0)
        #expect(device.currentWorkspace == edited)
        #expect(device.hasUnsavedChanges)
    }

    @Test func putsBackAWorkspaceWhoseSlotIsEmpty() async throws {
        let device = Self.device { options in
            options.currentSlot = 7
            options.workspace = .sample(seed: 60)
        }
        let backup = try await Self.backUp(device)
        #expect(backup.currentSlot == 7)
        #expect(device.currentWorkspace == .sample(seed: 60))
    }

    @Test func leavesOutAnEmptySampleBank() async throws {
        let backup = try await Self.backUp(Self.device { $0.sampleBank = nil })
        #expect(backup.samples == nil)
    }

    @Test func waitsForABusySampleBank() async throws {
        await #expect(throws: FM1UpdateError.sampleBankBusy) {
            try await Self.backUp(Self.device { $0.sampleState = 3 })
        }
    }

    @Test func refusesAnyFirmwareButOpenFirmware() async throws {
        await #expect(throws: FM1UpdateError.backupNeedsOpenFirmware(device: "FM-1_015")) {
            try await Self.backUp(Self.device { $0.installedIdentity = .officialV15 })
        }
    }

    @Test func reportsAFirmwareThatStopsAnswering() async throws {
        // The info, sample info, and workspace reads (open, 64 parts, close) answer; then nothing.
        let device = Self.device { $0.stopsAnsweringLibraryAfter = 2 + 66 + 3 }
        await #expect(throws: FM1UpdateError.backupStalled) {
            try await Self.backUp(device)
        }
    }

    @Test func reportsAFirmwareWithoutAProjectLibrary() async throws {
        await #expect(throws: FM1UpdateError.projectLibraryUnavailable) {
            try await Self.backUp(Self.device { $0.stopsAnsweringLibraryAfter = 0 })
        }
    }

    @Test func writesFilesTheWorkbenchReads() async throws {
        let backup = try await Self.backUp(Self.device())
        let folder = FileManager.default.temporaryDirectory.appending(path: "fm1kit-backup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let written = try backup.write(to: folder)
        #expect(
            Set(written.map(\.lastPathComponent)) == [
                "workspace.fm1", "slot-01.fm1", "slot-04.fm1", "samples.fm1s", "backup.json",
            ])
        let slot = try Data(contentsOf: folder.appending(path: "slot-04.fm1"))
        #expect(OpenFirmwareProject(fileData: slot) == .sample(seed: 4))
        #expect(try Data(contentsOf: folder.appending(path: "samples.fm1s")) == Data(Self.samples))

        let manifest = try JSONDecoder.iso8601.decode(
            OpenFirmwareBackupManifest.self, from: Data(contentsOf: folder.appending(path: "backup.json")))
        #expect(manifest.identity == "FM-1_8000012")
        #expect(manifest.currentSlot == 1)
        #expect(manifest.slots.count == 16)
        #expect(manifest.slots[3].name == "ACID LINE")
        #expect(manifest.slots[3].file == "slot-04.fm1")
        #expect(manifest.slots[1].file == nil)
        #expect(manifest.sampleBytes == Self.samples.count)
    }
}

extension JSONDecoder {
    /// A decoder for dates written as ISO 8601.
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
