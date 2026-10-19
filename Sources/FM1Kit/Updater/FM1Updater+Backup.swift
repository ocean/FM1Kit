import Foundation

/// Backing up an FM-1 running M-VAVE's open firmware, through its project library.
extension FM1Updater {
    /// Reads the project slots, the workspace and the sample bank from an FM-1 running M-VAVE's
    /// open firmware.
    ///
    /// The firmware can only read the project being edited, so this loads each slot into the
    /// workspace in turn, then puts the workspace back as it was, including unsaved changes. It
    /// never saves a slot or writes the sample bank, but while it runs, the FM-1's current project
    /// changes, so ask the person not to play or edit until it finishes. If it's interrupted,
    /// the FM-1 may be left on another slot's project, with any unsaved changes lost.
    ///
    /// Other firmwares have no known way to read their data, so they can't be backed up.
    ///
    /// - Parameter progress: Called with the share of the backup read so far (0 to 1); it may be
    ///   called from any task.
    /// - Returns: The backup, ready to ``OpenFirmwareBackup/write(to:)``.
    /// - Throws: ``FM1UpdateError`` when the FM-1 isn't running open firmware, more than one FM-1
    ///   answers, or the firmware refuses or stops answering; or `CancellationError`.
    public func backUpOpenFirmware(
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> OpenFirmwareBackup {
        guard let device = try await findOnly(where: { _ in true }) else { throw FM1UpdateError.deviceNotFound }
        defer { device.connection.close() }
        guard device.identity.isOpenFirmware else {
            throw FM1UpdateError.backupNeedsOpenFirmware(device: device.identity.text)
        }
        let library = ProjectLibrary(connection: device.connection, timing: timing)
        let layout = try await library.layout()
        let sampleInfo = try await library.request(.sampleInfo)
        guard sampleInfo.count == 9, let sampleState = ProjectLibraryMessage.SampleState(rawValue: sampleInfo[0]) else {
            throw FM1UpdateError.projectLibraryUnavailable
        }
        if sampleState == .validating || sampleState == .receiving { throw FM1UpdateError.sampleBankBusy }
        let sampleLength = sampleState == .ready ? Int(FM1Message.readLittleEndian(sampleInfo, at: 1, byteCount: 4)) : 0

        // Count progress in bytes read, treating every slot as full until it's found empty.
        let total = Double((layout.slotCount + 1) * layout.projectLength + sampleLength)
        var done = 0
        progress(0)

        let workspace = try await library.downloadProject()
        done += layout.projectLength
        progress(Double(done) / total)

        var slots: [OpenFirmwareBackup.Slot] = []
        var hasLoadedSlot = false
        do {
            for index in 0..<layout.slotCount {
                try Task.checkCancellation()
                if let name = try await library.slotName(index) {
                    hasLoadedSlot = true
                    try await library.request(.loadSlot, payload: [UInt8(index)])
                    let project = try await library.downloadProject()
                    slots.append(OpenFirmwareBackup.Slot(index: index, name: name, project: project))
                } else {
                    slots.append(OpenFirmwareBackup.Slot(index: index, name: nil, project: nil))
                }
                done += layout.projectLength
                progress(Double(done) / total)
            }
        } catch {
            // Put the workspace back if the FM-1 still answers; the original error matters more.
            if hasLoadedSlot {
                try? await library.restoreWorkspace(workspace, slot: layout.currentSlot, slots: slots)
            }
            throw error
        }
        try await library.restoreWorkspace(workspace, slot: layout.currentSlot, slots: slots)

        var samples: Data?
        if sampleLength > 0 {
            samples = try await library.readSamples(length: sampleLength) { read in
                progress(Double(done + read) / total)
            }
        }
        progress(1)
        return OpenFirmwareBackup(
            identity: device.identity,
            date: Date(),
            currentSlot: layout.currentSlot,
            workspace: workspace,
            slots: slots,
            samples: samples
        )
    }
}

/// Requests to open firmware's project library over one connection.
final class ProjectLibrary {
    /// What the library's info reply reports.
    struct Layout {
        var slotCount: Int
        var currentSlot: Int
        var projectLength: Int
    }

    private let connection: any MIDIConnection
    private let timing: UpdaterTiming
    private var token = Int.random(in: 0...ProjectLibraryMessage.tokenMask)

    /// The slot count every open firmware reports.
    static let slotCount = 16
    /// How many times to send a request before giving up; the firmware answers a repeat with
    /// its cached reply.
    static let attempts = 3

    init(connection: any MIDIConnection, timing: UpdaterTiming) {
        self.connection = connection
        self.timing = timing
    }

    /// Asks for the library's layout and checks it's one FM1Kit knows.
    func layout() async throws -> Layout {
        let info: [UInt8]
        do {
            info = try await request(.info)
        } catch FM1UpdateError.backupStalled {
            throw FM1UpdateError.projectLibraryUnavailable
        }
        guard
            info.count == 14, info[0] == 3 || info[0] == 4,
            Int(info[1]) == Self.slotCount, Int(info[2]) < Self.slotCount,
            OpenFirmwareProject.lengths.contains(Int(FM1Message.readLittleEndian(info, at: 3, byteCount: 2)))
        else {
            throw FM1UpdateError.projectLibraryUnavailable
        }
        let projectLength = Int(FM1Message.readLittleEndian(info, at: 3, byteCount: 2))
        return Layout(slotCount: Self.slotCount, currentSlot: Int(info[2]), projectLength: projectLength)
    }

    /// A slot's name, or `nil` when it's empty.
    func slotName(_ index: Int) async throws -> String? {
        guard let name = try await request(.slotName, payload: [UInt8(index)], allowsEmpty: true) else { return nil }
        let printable = name.filter { (0x20...0x7E).contains($0) }
        return (String(bytes: printable, encoding: .ascii) ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// Reads the workspace.
    func downloadProject() async throws -> OpenFirmwareProject {
        let head = try await request(.openRead, payload: [ProjectLibraryMessage.Kind.project.rawValue, 0])
        do {
            let length = head.count == 2 ? Int(FM1Message.readLittleEndian(head, at: 0, byteCount: 2)) : 0
            guard OpenFirmwareProject.lengths.contains(length) else { throw FM1UpdateError.projectLibraryUnavailable }
            var bytes: [UInt8] = []
            bytes.reserveCapacity(length)
            while bytes.count < length {
                let count = min(ProjectLibraryMessage.maximumReadLength, length - bytes.count)
                let offset = FM1Message.littleEndian(UInt32(bytes.count), byteCount: 2)
                let part = try await request(.read, payload: offset + [UInt8(count)])
                guard part.count == count else { throw FM1UpdateError.projectLibraryUnavailable }
                bytes += part
            }
            try await request(.closeTransfer)
            guard let project = OpenFirmwareProject(bytes: bytes) else {
                throw FM1UpdateError.projectLibraryUnavailable
            }
            return project
        } catch {
            _ = try? await request(.closeTransfer)
            throw error
        }
    }

    /// Writes a project into the workspace, as the firmware's import does; no slot is saved.
    func uploadProject(_ project: OpenFirmwareProject) async throws {
        let bytes = project.bytes
        let kind = ProjectLibraryMessage.Kind.project.rawValue
        try await request(.openWrite, payload: [kind, 0] + FM1Message.littleEndian(UInt32(bytes.count), byteCount: 2))
        do {
            for offset in stride(from: 0, to: bytes.count, by: ProjectLibraryMessage.maximumReadLength) {
                let end = min(offset + ProjectLibraryMessage.maximumReadLength, bytes.count)
                try await request(
                    .write, payload: FM1Message.littleEndian(UInt32(offset), byteCount: 2) + bytes[offset..<end])
            }
            try await request(.finishWrite, payload: FM1Message.littleEndian(CRC32.checksum(bytes), byteCount: 4))
        } catch {
            _ = try? await request(.closeTransfer)
            throw error
        }
    }

    /// Puts the workspace back as it was before the slots were read: reloads its slot, and
    /// writes the saved workspace over it when it held unsaved changes (or its slot is empty).
    func restoreWorkspace(_ workspace: OpenFirmwareProject, slot: Int, slots: [OpenFirmwareBackup.Slot]) async throws {
        let saved = slots.first { $0.index == slot }
        if saved?.project != nil {
            try await request(.loadSlot, payload: [UInt8(slot)])
            if saved?.project == workspace { return }
        } else if saved == nil, try await slotName(slot) != nil {
            // The slot wasn't reached before an error; reload it before writing the workspace.
            try await request(.loadSlot, payload: [UInt8(slot)])
        }
        try await uploadProject(workspace)
    }

    /// Reads the sample bank.
    func readSamples(length: Int, progress: (Int) -> Void) async throws -> Data {
        var samples = Data(capacity: length)
        while samples.count < length {
            try Task.checkCancellation()
            let count = min(ProjectLibraryMessage.maximumReadLength, length - samples.count)
            let part = try await request(
                .readSamples, payload: FM1Message.littleEndian(UInt32(samples.count), byteCount: 4) + [UInt8(count)])
            guard part.count == count else { throw FM1UpdateError.projectLibraryUnavailable }
            samples.append(contentsOf: part)
            progress(samples.count)
        }
        return samples
    }

    /// Sends a request and waits for its reply, sending it again if none comes.
    ///
    /// - Returns: The reply's payload after its status.
    @discardableResult
    func request(_ command: ProjectLibraryMessage.Command, payload: [UInt8] = []) async throws -> [UInt8] {
        // A reply about an empty slot only comes when it's allowed.
        try await request(command, payload: payload, allowsEmpty: false) ?? []
    }

    /// Sends a request and waits for its reply, sending it again if none comes.
    ///
    /// - Returns: The reply's payload after its status, or `nil` for an empty slot when `allowsEmpty`.
    func request(
        _ command: ProjectLibraryMessage.Command,
        payload: [UInt8],
        allowsEmpty: Bool
    ) async throws -> [UInt8]? {
        token = (token + 1) & ProjectLibraryMessage.tokenMask
        let message = ProjectLibraryMessage.request(command, token: token, payload: payload)
        let replyCommand = command.rawValue | ProjectLibraryMessage.replyBit
        connection.drain()
        for _ in 0..<Self.attempts {
            guard (try? connection.send(message)) != nil else { break }
            let deadline = ContinuousClock.now + timing.libraryReplyWait
            while ContinuousClock.now < deadline, !connection.isLost {
                guard let reply = await connection.receive(timeout: deadline - ContinuousClock.now) else { continue }
                guard let parsed = ProjectLibraryMessage.parse(reply), parsed.command == replyCommand,
                    parsed.token == token, let status = parsed.payload.first
                else {
                    continue
                }
                if status == ProjectLibraryMessage.success { return Array(parsed.payload.dropFirst()) }
                if status == ProjectLibraryMessage.empty, allowsEmpty { return nil }
                throw FM1UpdateError.backupRefused(code: Int(status))
            }
            if connection.isLost { break }
        }
        throw FM1UpdateError.backupStalled
    }
}
