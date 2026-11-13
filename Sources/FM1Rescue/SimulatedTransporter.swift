#if os(macOS)
import FM1Kit
import Foundation

/// An FM-1 Transporter wired to a simulated FM-1, answering its data port's requests as its
/// firmware does, for tests and `--simulated` runs.
public final class SimulatedTransporter: TransporterLink {
    /// The simulated FM-1's flash.
    public private(set) var flash: [UInt8]
    /// The flash ID the chip reports.
    public var flashID: UInt32 = FM1FlashChip.p25q80
    /// The FM-1 is switched off, so only `ping` is answered until ``switchOn()``.
    public var isWaitingForFM1 = false
    /// Requests the simulated person switches the FM-1 on after, when it's waiting.
    public var switchesOnAfter = 0
    /// The FM-1 is running V15 rather than in boot mode.
    public var isRunningV15 = false
    /// The sector whose write fails, if any.
    public var failingSector: Int?
    /// Corrupts the next read's bytes.
    public var corruptsNextRead = false
    /// The Transporter's firmware takes a loader's address and size, as v0.1.0's doesn't.
    public var takesAnyLoader = true
    /// Where the loader was sent to run.
    public private(set) var loaderAddress: UInt32 = 0x1C0_2000
    /// The sectors written, in order.
    public private(set) var writtenSectors: [Int] = []

    private var output: [UInt8] = []
    private var input: [UInt8] = []
    private var unanswered: [String] = []
    private var loader: [UInt8] = []
    private var loaderSize = 24_064
    private var isLoaderRunning = false

    /// A Transporter wired to an FM-1 in boot mode holding `flash`.
    ///
    /// - Parameter flash: The FM-1's 1 MB of flash.
    public init(flash: [UInt8]) {
        self.flash = flash
    }

    /// The simulated person switches the FM-1 on: the boot ROM answers, and requests sent while
    /// it was off are answered.
    public func switchOn() {
        isWaitingForFM1 = false
        let held = unanswered
        unanswered.removeAll()
        for request in held { answer(request, payload: []) }
    }

    /// Sends bytes to the simulated Transporter.
    public func send(_ bytes: [UInt8]) throws(TransporterError) {
        input += bytes
        while let end = input.firstIndex(of: 0x0A) {
            let line = String(bytes: input[..<end], encoding: .utf8) ?? ""
            let length = payloadLength(line)
            guard input.count >= end + 1 + length else { return }
            let payload = Array(input[(end + 1)..<(end + 1 + length)])
            input.removeFirst(end + 1 + length)
            answer(line, payload: payload)
        }
    }

    /// Waits for bytes from the simulated Transporter.
    public func receive(timeout _: Duration) throws(TransporterError) -> [UInt8] {
        if output.isEmpty, isWaitingForFM1, !unanswered.isEmpty {
            if switchesOnAfter <= 0 { switchOn() } else { switchesOnAfter -= 1 }
        }
        // A real port waits for bytes; a short pause keeps callers from spinning.
        if output.isEmpty { Thread.sleep(forTimeInterval: 0.001) }
        let bytes = output
        output.removeAll()
        return bytes
    }

    /// Closes the simulated Transporter.
    public func close() {}

    /// The bytes that follow a request line.
    private func payloadLength(_ line: String) -> Int {
        let words = line.split(separator: " ")
        switch words.first {
        case "wsec": return FlashPlan.sectorLength
        case "ldr" where words.count >= 4: return Int(words[2]) ?? 0
        default: return 0
        }
    }

    private func reply(_ line: String) {
        output += Array("\(line)\n".utf8)
    }

    private func answer(_ line: String, payload: [UInt8]) {
        let words = line.split(separator: " ").map(String.init)
        guard let command = words.first else { return }
        if command == "ping" {
            reply("PONG")
        } else if isWaitingForFM1 {
            unanswered.append(line)
        } else if command == "read" {
            read(words)
        } else {
            reply(response(to: words, payload: payload))
        }
    }

    /// The one-line answer to a request other than `read`.
    private func response(to words: [String], payload: [UInt8]) -> String {
        let hasLoader = loader.count == loaderSize
        switch words[0] {
        case "status":
            return "OK uboot=\(isRunningV15 ? 0 : 1) v15=\(isRunningV15 ? 1 : 0) loader=\(hasLoader ? 1 : 0)"
                + " loader_running=\(isLoaderRunning ? 1 : 0)"
        case "uboot":
            defer { isRunningV15 = false }
            return isRunningV15 ? "OK softkey" : "OK uboot"
        case "ldr" where words.count == 4 || words.count == 6:
            let placement = takesAnyLoader && words.count == 6 ? Array(words[4...]) : []
            return load(offset: Int(words[1]) ?? -1, crc: words[3], placement: placement, payload: payload)
        case "info":
            isLoaderRunning = isLoaderRunning || hasLoader
            return hasLoader ? String(format: "OK key=980F type=3 id=%06X", flashID) : "ERR info"
        case "wsec" where words.count == 3:
            return write(at: Int(words[1].dropFirst(2), radix: 16) ?? -1, crc: words[2], payload: payload)
        case "runapp":
            return "OK"
        default:
            return "ERR unknown"
        }
    }

    private func load(offset: Int, crc: String, placement: [String], payload: [UInt8]) -> String {
        if offset == 0 {
            loader.removeAll()
            loaderAddress = placement.first.flatMap { UInt32($0.dropFirst(2), radix: 16) } ?? 0x1C0_2000
            loaderSize = placement.last.flatMap { Int($0) } ?? 24_064
        }
        guard offset == loader.count, crc == Transporter.hex(ChipChecksum.crc32(payload)) else {
            return "ERR loader-range"
        }
        loader += payload
        return "OK"
    }

    private func read(_ words: [String]) {
        guard words.count == 3, let address = Int(words[1].dropFirst(2), radix: 16), let count = Int(words[2]),
            address + count <= flash.count
        else {
            reply("ERR range")
            return
        }
        guard loader.count == loaderSize else {
            reply("ERR loader")
            return
        }
        var bytes = Array(flash[address..<(address + count)])
        let crc = ChipChecksum.crc32(bytes)
        if corruptsNextRead {
            bytes[count / 2] ^= 0xFF
            corruptsNextRead = false
        }
        reply("DATA \(count)")
        output += bytes
        reply("END \(Transporter.hex(crc))")
    }

    private func write(at address: Int, crc: String, payload: [UInt8]) -> String {
        let actual = Transporter.hex(ChipChecksum.crc32(payload))
        guard crc == actual else { return "ERR crc \(actual)" }
        guard FlashPlan.transporterWritable.contains(address), address.isMultiple(of: FlashPlan.sectorLength) else {
            return "ERR range"
        }
        guard address != failingSector else { return "ERR write" }
        flash.replaceSubrange(address..<(address + FlashPlan.sectorLength), with: payload)
        writtenSectors.append(address)
        return "OK"
    }
}
#endif
