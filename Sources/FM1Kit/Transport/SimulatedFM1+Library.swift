import os

/// The simulated FM-1's answers to open firmware's project library, which reads projects and
/// the sample bank.
extension SimulatedFM1 {
    /// A saved project slot on simulated open firmware.
    public struct ProjectSlot: Sendable, Hashable {
        /// The project's name, up to 12 characters.
        public var name: String
        /// The project.
        public var project: OpenFirmwareProject

        /// Makes a slot.
        public init(name: String, project: OpenFirmwareProject) {
            self.name = name
            self.project = project
        }
    }

    /// What the simulated open firmware's project library holds and is doing.
    struct LibraryState {
        /// The project being edited.
        var workspace: OpenFirmwareProject
        /// The slot the workspace was loaded from.
        var currentSlot: Int
        /// True when the workspace differs from its slot.
        var hasUnsavedChanges = false
        /// What a read is serving, captured when it started.
        var reading: [UInt8]?
        /// What a write has received so far.
        var written: [UInt8] = []
        /// How long the write in progress will be, or `nil` when none is.
        var writeLength: Int?
        /// Requests answered so far.
        var requests = 0
    }

    /// The simulated open firmware's workspace.
    public var currentWorkspace: OpenFirmwareProject {
        state.withLock { $0.library.workspace }
    }

    /// The slot the simulated open firmware's workspace was loaded from.
    public var currentSlot: Int {
        state.withLock { $0.library.currentSlot }
    }

    /// True when the simulated open firmware's workspace holds changes its slot doesn't.
    public var hasUnsavedChanges: Bool {
        state.withLock { $0.library.hasUnsavedChanges }
    }

    /// Answers a project library request, as open firmware does; other firmwares ignore them.
    func handleLibraryRequest(_ request: ProjectLibraryMessage.Parsed, from connection: SimulatedConnection) {
        guard currentIdentity?.isOpenFirmware == true, request.command < ProjectLibraryMessage.replyBit else { return }
        let reply: [UInt8]? = state.withLock { state in
            if let limit = options.stopsAnsweringLibraryAfter, state.library.requests >= limit { return nil }
            state.library.requests += 1
            guard let command = ProjectLibraryMessage.Command(rawValue: request.command) else { return Self.invalid }
            return
                projectReply(command, payload: request.payload, library: &state.library)
                ?? transferReply(command, payload: request.payload, library: &state.library)
                ?? sampleReply(command, payload: request.payload)
        }
        guard let reply else {
            log("Stopped answering the project library.")
            return
        }
        let replyCommand = request.command | ProjectLibraryMessage.replyBit
        connection.toHost.deliver(ProjectLibraryMessage.frame(replyCommand, token: request.token, payload: reply))
    }

    /// The status open firmware gives an invalid request: 64 minus its error code, −7.
    private static let invalid: [UInt8] = [71]
    private static let success = ProjectLibraryMessage.success

    /// The reply to a request about the library's layout or its slots, or `nil` for other requests.
    private func projectReply(
        _ command: ProjectLibraryMessage.Command,
        payload: [UInt8],
        library: inout LibraryState
    ) -> [UInt8]? {
        switch command {
        case .info:
            let length = FM1Message.littleEndian(UInt32(library.workspace.bytes.count), byteCount: 2)
            return [Self.success, 4, 16, UInt8(library.currentSlot)] + length + Array(repeating: 0, count: 9)
        case .slotName:
            guard payload.count == 1 else { return Self.invalid }
            guard let slot = options.projectSlots[Int(payload[0])] else {
                return [ProjectLibraryMessage.empty] + Array("EMPTY       ".utf8)
            }
            return [Self.success] + Array(slot.name.utf8.prefix(12))
                + Array(repeating: 0x20, count: 12 - min(12, slot.name.utf8.count))
        case .loadSlot:
            guard payload.count == 1, let slot = options.projectSlots[Int(payload[0])] else {
                return [ProjectLibraryMessage.empty]
            }
            library.workspace = slot.project
            library.currentSlot = Int(payload[0])
            library.hasUnsavedChanges = false
            return [Self.success]
        default:
            return nil
        }
    }

    /// The reply to a request that reads or writes the workspace, or `nil` for other requests.
    private func transferReply(
        _ command: ProjectLibraryMessage.Command,
        payload: [UInt8],
        library: inout LibraryState
    ) -> [UInt8]? {
        let project = ProjectLibraryMessage.Kind.project.rawValue
        switch command {
        case .openRead:
            guard payload == [project, 0] else { return Self.invalid }
            library.reading = library.workspace.bytes
            return [Self.success] + FM1Message.littleEndian(UInt32(library.workspace.bytes.count), byteCount: 2)
        case .read:
            guard payload.count == 3, let reading = library.reading else { return Self.invalid }
            return Self.part(
                of: reading, at: Int(FM1Message.readLittleEndian(payload, at: 0, byteCount: 2)), count: Int(payload[2]))
        case .openWrite:
            guard payload.count == 4, payload[0] == project else { return Self.invalid }
            library.written = []
            library.writeLength = Int(FM1Message.readLittleEndian(payload, at: 2, byteCount: 2))
            return [Self.success]
        case .write:
            guard payload.count > 2, library.writeLength != nil,
                Int(FM1Message.readLittleEndian(payload, at: 0, byteCount: 2)) == library.written.count
            else {
                return Self.invalid
            }
            library.written += payload[2...]
            return [Self.success]
        case .finishWrite:
            guard payload.count == 4, library.written.count == library.writeLength,
                FM1Message.readLittleEndian(payload, at: 0, byteCount: 4) == CRC32.checksum(library.written),
                let received = OpenFirmwareProject(bytes: library.written)
            else {
                return Self.invalid
            }
            library.workspace = received
            library.hasUnsavedChanges = true
            library.writeLength = nil
            return [Self.success]
        case .closeTransfer:
            library.reading = nil
            library.writeLength = nil
            return [Self.success]
        default:
            return nil
        }
    }

    /// The reply to a request about the sample bank.
    private func sampleReply(_ command: ProjectLibraryMessage.Command, payload: [UInt8]) -> [UInt8] {
        let bank = options.sampleBank ?? []
        switch command {
        case .sampleInfo:
            let state = bank.isEmpty ? ProjectLibraryMessage.SampleState.empty.rawValue : options.sampleState
            return [Self.success, state] + FM1Message.littleEndian(UInt32(bank.count), byteCount: 4)
                + FM1Message.littleEndian(466_944, byteCount: 4)
        case .readSamples:
            guard payload.count == 5 else { return Self.invalid }
            return Self.part(
                of: bank, at: Int(FM1Message.readLittleEndian(payload, at: 0, byteCount: 4)), count: Int(payload[4]))
        default:
            return Self.invalid
        }
    }

    /// A successful reply with up to 64 bytes from `bytes`, or an invalid one if they're out of range.
    private static func part(of bytes: [UInt8], at offset: Int, count: Int) -> [UInt8] {
        guard count > 0, count <= ProjectLibraryMessage.maximumReadLength, offset + count <= bytes.count else {
            return invalid
        }
        return [success] + bytes[offset..<(offset + count)]
    }
}
