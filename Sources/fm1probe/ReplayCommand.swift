import FM1Kit
import Foundation

/// One row of a log that `install --log`, `monitor --log` and the others write.
struct LoggedMessage {
    let seconds: Double
    let direction: MessageLog.Direction
    let port: String
    let kind: String
    let address: UInt32?
    let length: Int?
    let size: Int
    /// The message, when the log kept its bytes: install logs leave out those over 48 bytes.
    let bytes: [UInt8]?

    /// Parses a row; `nil` for the header or a row that isn't one of fm1probe's.
    init?(csvLine line: String) {
        let fields = Self.fields(line)
        guard fields.count == 9, let seconds = Double(fields[0]),
            let direction = MessageLog.Direction(rawValue: fields[1]), let size = Int(fields[7])
        else {
            return nil
        }
        self.seconds = seconds
        self.direction = direction
        port = fields[2]
        kind = fields[3]
        address = fields[5].hasPrefix("0x") ? UInt32(fields[5].dropFirst(2), radix: 16) : nil
        length = Int(fields[6])
        self.size = size
        let bytes = fields[8].split(separator: " ").compactMap { UInt8($0, radix: 16) }
        self.bytes = bytes.isEmpty ? nil : bytes
    }

    /// What the message is: decoded again from its bytes when the log kept them, so an old log
    /// gains what fm1probe has learnt since; otherwise from the log's own columns.
    var description: FM1MessageDescription? {
        bytes.map { FM1MessageDescription($0, direction: direction == .toDevice ? .toDevice : .fromDevice) }
    }

    /// The text to print for this message.
    var text: String {
        if let description { return description.text }
        if let address, let length { return "\(kind): " + String(format: "0x%08X", address) + ", \(length) bytes" }
        return "\(kind): \(size) bytes"
    }

    /// The message's kind, as decoded now when possible.
    var currentKind: String {
        description?.kind ?? kind
    }

    /// Splits a CSV line, keeping commas inside double quotes, as the port's name may have.
    private static func fields(_ line: String) -> [String] {
        var fields: [String] = []
        var field = ""
        var isQuoted = false
        for character in line {
            switch character {
            case "\"": isQuoted.toggle()
            case "," where !isQuoted:
                fields.append(field)
                field = ""
            default: field.append(character)
            }
        }
        fields.append(field)
        return fields
    }
}

/// A run of image reads and their responses, printed as one line unless `replay --all`.
private struct ReadRun {
    var start: Double
    var end: Double
    var reads = 0
    var responses = 0
    var lowest = UInt32.max
    var highest: UInt32 = 0
    var addresses: Set<UInt32> = []
    var repeats = 0

    init(at seconds: Double) {
        start = seconds
        end = seconds
    }

    mutating func add(_ message: LoggedMessage) {
        end = message.seconds
        guard message.direction == .fromDevice else {
            responses += 1
            return
        }
        reads += 1
        guard let address = message.address else { return }
        if !addresses.insert(address).inserted { repeats += 1 }
        lowest = min(lowest, address)
        highest = max(highest, address + UInt32(message.length ?? 0))
    }

    var text: String {
        let range = reads > 0 && lowest <= highest ? String(format: "0x%08X–0x%08X", lowest, highest &- 1) + ", " : ""
        let repeated = repeats == 0 ? "" : ", \(repeats) asked for again"
        return "reads: \(range)\(reads) requests, \(responses) responses over "
            + String(format: "%.1f s", end - start) + repeated
    }
}

/// Prints a message log, naming each message, with runs of image reads summed up unless
/// `showsEveryMessage`, and then a summary: counts by kind, identities and the longest silence.
func replay(path: String, showsEveryMessage: Bool) throws {
    let text = try String(contentsOfFile: path, encoding: .utf8)
    let messages = text.split(whereSeparator: \.isNewline).compactMap { LoggedMessage(csvLine: String($0)) }
    guard !messages.isEmpty else {
        let isLog = text.hasPrefix("seconds,direction,port,kind,")
        print(isLog ? "\(path) has no messages." : "\(path) isn't a log fm1probe wrote.")
        fail()
    }
    let ports = Set(messages.map(\.port))
    let portWidth = ports.count > 1 ? ports.map(\.count).max() ?? 0 : 0
    func line(_ seconds: Double, _ direction: String, _ port: String, _ text: String) {
        let columns =
            [direction.padding(toLength: 3, withPad: " ", startingAt: 0)]
            + (portWidth > 0 ? [port.padding(toLength: portWidth, withPad: " ", startingAt: 0)] : [])
        print(String(format: "%9.3f", seconds) + "  " + (columns + [text]).joined(separator: "  "))
    }
    var run: ReadRun?
    var counts: [String: Int] = [:]
    var identities: [String] = []
    var longestSilence = (length: 0.0, after: 0.0)
    var previous = messages[0].seconds
    for message in messages {
        let kind = message.currentKind
        counts[kind, default: 0] += 1
        if kind.hasPrefix("identity "), identities.last != kind { identities.append(kind) }
        if message.seconds - previous > longestSilence.length {
            longestSilence = (message.seconds - previous, previous)
        }
        previous = message.seconds
        // A response outside a run of reads, such as the answer to a finish, gets a line of its own.
        if !showsEveryMessage, kind == "read" || (kind == "response" && run != nil) {
            if run == nil { run = ReadRun(at: message.seconds) }
            run?.add(message)
            continue
        }
        if let finished = run {
            line(finished.start, "", "", finished.text)
            run = nil
        }
        line(message.seconds, message.direction.rawValue, message.port, message.text)
    }
    if let run { line(run.start, "", "", run.text) }

    print("")
    let duration = String(format: "%.1f s", messages[messages.count - 1].seconds - messages[0].seconds)
    let sent = messages.filter { $0.direction == .toDevice }.count
    print("\(messages.count) messages over \(duration): \(sent) to the device, \(messages.count - sent) from it.")
    for (kind, count) in counts.sorted(by: { ($0.value, $1.key) > ($1.value, $0.key) }) {
        print("  \(String(count).leftPadded(to: 7))  \(kind)")
    }
    if !identities.isEmpty {
        print("Identities, in order: " + identities.map { $0.dropFirst("identity ".count) }.joined(separator: ", "))
    }
    if longestSilence.length > 0 {
        print(String(format: "Longest silence: %.3f s, after %.3f s.", longestSilence.length, longestSilence.after))
    }
}

extension String {
    fileprivate func leftPadded(to length: Int) -> String {
        count >= length ? self : String(repeating: " ", count: length - count) + self
    }
}
