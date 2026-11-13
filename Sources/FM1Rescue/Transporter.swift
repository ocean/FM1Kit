#if os(macOS)
import FM1Kit
import Foundation

/// The FM-1 Transporter: an RP2040 board wired to the FM-1's USB lines that reaches the chip's
/// boot ROM when the FM-1's firmware can't start.
///
/// The Transporter's firmware is kurogedelic's
/// [FM-1 Transporter](https://github.com/kurogedelic/FM-1-transporter) (MIT). It sends the boot
/// ROM's USB key at power-on, acts as the FM-1's USB host, and takes line requests on its data
/// port. Reads need a flash loader, which it keeps in its RAM and starts on the chip:
/// m-bootloader's, or jl-uboot-tool's `wl82loader.bin` (see ``Loader``). Its firmware writes only
/// whole sectors in ``FlashPlan/transporterWritable``.
///
/// Every call blocks until the Transporter answers, so call it off the main thread.
public final class Transporter {
    /// What the Transporter reports.
    public struct Status: Sendable, Hashable {
        /// The FM-1 is in its boot ROM's download mode.
        public var isInBootMode: Bool
        /// The FM-1 is running stock V15, which can be asked to switch to boot mode.
        public var isRunningV15: Bool
        /// The flash loader has been sent to the Transporter.
        public var hasLoader: Bool
        /// The flash loader is running on the chip, where it stays until the FM-1 is switched off.
        public var isLoaderRunning = false
    }

    /// The flash loader the Transporter starts on the chip.
    public enum Loader: Sendable, Hashable {
        /// m-bootloader's flash loader (MIT), built into FM1Rescue. The Transporter's firmware
        /// must take a loader's address and size, which v0.1.0's doesn't.
        case mBootloader
        /// jl-uboot-tool's `wl82loader.bin`, which every Transporter firmware takes.
        case wl82loader([UInt8])
    }

    /// What the chip reports through the flash loader.
    public struct Chip: Sendable, Hashable {
        /// The chip's encryption key; M-VAVE's FM-1s use `0x980F`.
        public var key: UInt16
        /// The flash chip's JEDEC ID, such as `0x856014`.
        public var flashID: UInt32
    }

    /// The SHA-256 of jl-uboot-tool's `wl82loader.bin`, the flash loader the Transporter starts.
    public static let loaderSHA256 = "d41da6126760c9d66660bcc0cac8d27d221806c5e369a8036921efe68dca5376"

    let link: any TransporterLink
    private var pending: [UInt8] = []
    /// The SHA-256 ``sendLoader(_:status:)`` accepts for `wl82loader.bin`.
    var acceptedLoaderSHA256 = loaderSHA256
    /// How backups name the loader that read them: the one ``sendLoader(_:status:)`` sent, or one
    /// already running that it left alone.
    private(set) var loaderDescription = "a flash loader already running, through the FM-1 Transporter"
    /// How long `status` may take before the FM-1 is taken to be switched off.
    var switchedOffAfter: Duration = .seconds(2)

    /// Bytes per loader request, the most the Transporter takes at once.
    static let loaderChunkLength = 4096

    /// Talks to a Transporter.
    ///
    /// - Parameter link: Its data port, such as ``SerialTransporterLink/find(path:)``.
    public init(link: any TransporterLink) {
        self.link = link
    }

    /// Closes the data port.
    public func close() {
        link.close()
    }

    // MARK: - Boot mode.

    /// Asks what the Transporter reports, without sending anything to the FM-1.
    ///
    /// - Returns: The status, or `nil` while the Transporter waits for the FM-1 to be switched
    ///   on, when it answers nothing but `ping`.
    /// - Throws: ``TransporterError`` when the Transporter answers something else.
    public func status() throws(TransporterError) -> Status? {
        try send("status")
        return try nextLine(timeout: switchedOffAfter).map(Self.status)
    }

    /// Waits for the FM-1 to reach its boot ROM's download mode.
    ///
    /// Until the boot ROM answers the Transporter's key, the Transporter answers nothing but
    /// `ping`, so a request sent then is answered only once the FM-1 is switched on. A running
    /// V15 is asked to switch over USB MIDI.
    ///
    /// - Parameters:
    ///   - timeout: How long to wait.
    ///   - waiting: Called once if the FM-1 needs switching on.
    /// - Returns: The Transporter's status in boot mode.
    /// - Throws: ``TransporterError/notInBootMode`` when the FM-1 doesn't get there in time.
    public func waitForBootMode(timeout: Duration, waiting: () -> Void = {}) throws(TransporterError) -> Status {
        let deadline = ContinuousClock.now + timeout
        try send("status")
        var answer = try nextLine(timeout: switchedOffAfter)
        if answer == nil {
            waiting()
            answer = try nextLine(timeout: max(deadline - ContinuousClock.now, .zero))
        }
        guard var reply = answer else { throw .notInBootMode }
        var askedV15 = false
        while true {
            let status = try Self.status(reply)
            if status.isInBootMode { return status }
            if status.isRunningV15, !askedV15 {
                let switched = try request("uboot", timeout: .seconds(5))
                guard switched.hasPrefix("OK") else { throw .refused("uboot", switched) }
                askedV15 = true
            }
            guard ContinuousClock.now < deadline else { throw .notInBootMode }
            Thread.sleep(forTimeInterval: 0.5)
            reply = try request("status", timeout: .seconds(5))
        }
    }

    /// Sends the flash loader, unless one is already running on the chip.
    ///
    /// - Parameters:
    ///   - loader: The loader.
    ///   - status: What ``waitForBootMode(timeout:waiting:)`` reported.
    /// - Throws: ``TransporterError/wrongLoader(_:)`` when a `wl82loader.bin` isn't that file,
    ///   ``TransporterError/loaderNotTaken`` when the Transporter's firmware takes only
    ///   `wl82loader.bin`, or another ``TransporterError`` when the Transporter refuses it.
    public func sendLoader(_ loader: Loader, status: Status) throws(TransporterError) {
        guard !status.isLoaderRunning else { return }
        let blob: [UInt8]
        var placement = ""
        switch loader {
        case .mBootloader:
            let image = FlashLoaderImage.bundled[0]
            // Sent as the ROM takes it, scrambled in 512-byte blocks, as wl82loader.bin is stored.
            blob = stride(from: 0, to: image.bytes.count, by: 512).flatMap { start in
                ChipChecksum.scramble(image.bytes[start..<min(start + 512, image.bytes.count)])
            }
            placement = " 0x\(String(image.address, radix: 16)) \(blob.count)"
            loaderDescription = "m-bootloader's flash loader \(image.version), through the FM-1 Transporter"
        case .wl82loader(let bytes):
            let sha256 = FwscPackage.sha256Hex(bytes)
            guard sha256 == acceptedLoaderSHA256 else { throw .wrongLoader(sha256) }
            blob = bytes
            loaderDescription = "jl-uboot-tool's wl82loader, through the FM-1 Transporter"
        }
        for offset in stride(from: 0, to: blob.count, by: Self.loaderChunkLength) {
            let chunk = Array(blob[offset..<min(offset + Self.loaderChunkLength, blob.count)])
            let header = "ldr \(offset) \(chunk.count) \(Self.hex(ChipChecksum.crc32(chunk)))"
            try send(Array("\(header)\(offset == 0 ? placement : "")\n".utf8) + chunk)
            let answer = try line(timeout: .seconds(5), for: "ldr")
            guard answer == "OK" else { throw .refused("ldr", answer) }
        }
        // Firmware that takes only wl82loader.bin stores a shorter loader without complaint, but
        // never counts it as whole.
        guard try self.status()?.hasLoader == true else { throw .loaderNotTaken }
    }

    /// Starts the flash loader and reads the chip key and flash ID, refusing a chip that isn't an
    /// FM-1's.
    ///
    /// - Returns: What the chip reports.
    /// - Throws: ``TransporterError/notAnFM1(chipKey:flashID:)`` for another chip, or another
    ///   ``TransporterError`` when the Transporter can't read it.
    public func chip() throws(TransporterError) -> Chip {
        let answer = try request("info", timeout: .seconds(10))
        let fields = Self.fields(answer)
        guard answer.hasPrefix("OK"), let key = fields["key"].flatMap({ UInt16($0, radix: 16) }),
            let flashID = fields["id"].flatMap({ UInt32($0, radix: 16) })
        else { throw .refused("info", answer) }
        guard key == FlashSession.expectedChipKey, FlashSession.fm1FlashIDs.contains(flashID) else {
            throw .notAnFM1(chipKey: key, flashID: flashID)
        }
        return Chip(key: key, flashID: flashID)
    }

    /// Leaves boot mode and starts the FM-1's firmware.
    ///
    /// - Throws: ``TransporterError`` when the Transporter refuses.
    public func startFirmware() throws(TransporterError) {
        let answer = try request("runapp", timeout: .seconds(5))
        guard answer == "OK" else { throw .refused("runapp", answer) }
    }

    // MARK: - Reading.

    /// Reads part of the flash, checked against the Transporter's CRC-32.
    ///
    /// - Parameters:
    ///   - range: The addresses.
    ///   - progress: Called with the bytes read so far.
    /// - Returns: The bytes.
    /// - Throws: ``TransporterError/readsDiffer`` when they don't match the CRC-32.
    public func read(_ range: Range<Int>, progress: (Int) -> Void = { _ in }) throws(TransporterError) -> [UInt8] {
        let request = "read 0x\(String(range.lowerBound, radix: 16)) \(range.count)"
        try send(request)
        let header = try line(timeout: .seconds(10), for: "read")
        guard header == "DATA \(range.count)" else { throw .refused("read", header) }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(range.count)
        while bytes.count < range.count {
            if pending.isEmpty {
                pending = try link.receive(timeout: .seconds(10))
                guard !pending.isEmpty else { throw .noReply("read") }
            }
            let count = min(pending.count, range.count - bytes.count)
            bytes += pending[0..<count]
            pending.removeFirst(count)
            progress(bytes.count)
        }
        let end = try line(timeout: .seconds(10), for: "read")
        guard end == "END \(Self.hex(ChipChecksum.crc32(bytes)))" else { throw .readsDiffer }
        return bytes
    }

    /// Reads the whole flash twice and checks both reads match, so a backup is never saved from a
    /// bad read.
    ///
    /// Nothing is written to the FM-1.
    ///
    /// - Parameters:
    ///   - chip: What ``chip()`` reported.
    ///   - progress: Called with the share read so far (0 to 1).
    /// - Returns: The backup, ready to ``FlashBackup/write(to:)``.
    /// - Throws: ``TransporterError/readsDiffer`` when the reads don't match.
    public func backUp(_ chip: Chip, progress: (Double) -> Void = { _ in }) throws(TransporterError) -> FlashBackup {
        let size = FlashSession.flashSize
        let first = try read(0..<size) { progress(Double($0) / Double(2 * size)) }
        let second = try read(0..<size) { progress(Double(size + $0) / Double(2 * size)) }
        guard first == second else { throw .readsDiffer }
        return FlashBackup(
            bytes: first,
            uniqueID: nil,
            chipKey: chip.key,
            flashID: chip.flashID,
            loaderVersion: loaderDescription,
            date: Date()
        )
    }

    // MARK: - Writing.

    /// Carries out a plan: writes only the sectors that change, then reads the flash back to check
    /// them.
    ///
    /// It works from the top of the flash down, so a firmware's start-up code, at the bottom of
    /// its area, is the last thing replaced. Save ``FlashPlan/original`` before calling this: it's
    /// the way back. The FM-1 must still hold that flash, which is checked first. Switching the
    /// FM-1 off while it writes can leave it unable to start until it's written again.
    ///
    /// - Parameters:
    ///   - plan: What to write; every sector must be in ``FlashPlan/transporterWritable``.
    ///   - progress: Called with the share written so far (0 to 1).
    /// - Throws: ``TransporterError/outsideWritableRange(_:)`` or
    ///   ``TransporterError/flashChanged`` before anything is written,
    ///   ``TransporterError/writeFailed(at:_:)`` when the Transporter refuses a sector, or
    ///   ``TransporterError/writeNotVerified(_:)`` when the flash doesn't read back as written.
    public func write(_ plan: FlashPlan, progress: (Double) -> Void = { _ in }) throws(TransporterError) {
        if let sector = plan.sectors.first(where: { !FlashPlan.transporterWritable.contains($0) }) {
            throw .outsideWritableRange(sector)
        }
        guard !plan.isEmpty else {
            progress(1)
            return
        }
        guard try read(0..<FlashSession.flashSize) == plan.original.bytes else { throw .flashChanged }
        progress(0)
        for (index, sector) in plan.sectors.reversed().enumerated() {
            let bytes = Array(plan.target[sector..<(sector + FlashPlan.sectorLength)])
            let header = "wsec 0x\(String(sector, radix: 16)) \(Self.hex(ChipChecksum.crc32(bytes)))"
            try send(Array("\(header)\n".utf8) + bytes)
            let answer: String
            do {
                answer = try line(timeout: .seconds(20), for: "wsec")
            } catch {
                throw .writeFailed(at: sector, "no answer")
            }
            guard answer == "OK" else { throw .writeFailed(at: sector, answer) }
            progress(Double(index + 1) / Double(plan.sectors.count + 1))
        }
        let written = try read(0..<FlashSession.flashSize)
        for sector in plan.sectors {
            let range = sector..<(sector + FlashPlan.sectorLength)
            guard written[range] == plan.target[range] else { throw .writeNotVerified(sector) }
        }
        progress(1)
    }

    // MARK: - Requests.

    private func send(_ request: String) throws(TransporterError) {
        try send(Array("\(request)\n".utf8))
    }

    private func send(_ bytes: [UInt8]) throws(TransporterError) {
        pending.removeAll()
        _ = try link.receive(timeout: .zero)
        try link.send(bytes)
    }

    private func request(_ request: String, timeout: Duration) throws(TransporterError) -> String {
        try send(request)
        return try line(timeout: timeout, for: request)
    }

    private func line(timeout: Duration, for request: String) throws(TransporterError) -> String {
        guard let line = try nextLine(timeout: timeout) else { throw .noReply(request) }
        return line
    }

    /// The next line, without its newline, or `nil` when none arrives in time.
    private func nextLine(timeout: Duration) throws(TransporterError) -> String? {
        let deadline = ContinuousClock.now + timeout
        while true {
            if let end = pending.firstIndex(of: 0x0A) {
                let line = String(bytes: pending[..<end], encoding: .utf8) ?? ""
                pending.removeFirst(end + 1)
                return line.trimmingCharacters(in: .whitespaces)
            }
            let left = deadline - ContinuousClock.now
            guard left > .zero else { return nil }
            pending += try link.receive(timeout: left)
        }
    }

    /// Reads the answer to `status`, such as "OK uboot=1 v15=0 loader=1".
    static func status(_ answer: String) throws(TransporterError) -> Status {
        let fields = fields(answer)
        guard answer.hasPrefix("OK"), let uboot = fields["uboot"], let v15 = fields["v15"],
            let loader = fields["loader"]
        else { throw .refused("status", answer) }
        return Status(
            isInBootMode: uboot == "1",
            isRunningV15: v15 == "1",
            hasLoader: loader == "1",
            isLoaderRunning: fields["loader_running"] == "1"
        )
    }

    /// The `name=value` fields of an answer.
    static func fields(_ answer: String) -> [String: String] {
        var fields: [String: String] = [:]
        for word in answer.split(separator: " ") {
            let parts = word.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { fields[String(parts[0])] = String(parts[1]) }
        }
        return fields
    }

    /// A CRC-32 as the Transporter writes it, such as `FF074A28`.
    static func hex(_ value: UInt32) -> String {
        String(format: "%08X", value)
    }
}
#endif
