import FM1Kit
import Foundation

/// Runs `identify`: asks each port that looks like an FM-1, or the one `--port` names, what it's
/// running, `--repeat` times, and reports the answers and how long they took.
func identify() async throws {
    let transport = try CoreMIDITransport(clientName: "fm1probe")
    let repeats = max(option("--repeat").flatMap(Int.init) ?? 1, 1)
    let ports = try await portsToIdentify(transport)
    var results: [IdentifyJSON.Port] = []
    for port in ports {
        if !isJSON {
            print("\(portLabel(port)):")
            if let serial = port.serialNumber { print("  serial: \(serial)") }
        }
        let answers = await ask(try await transport.open(port), repeats: repeats)
        results.append(answers.json(port: port, attempts: repeats))
        if !isJSON { printAnswers(answers, attempts: repeats) }
    }
    let answering = results.filter { $0.answered > 0 }.count
    if isJSON {
        printJSON(IdentifyJSON(ports: results))
    } else if answering > 1 {
        print("\(answering) FM-1s answered: run `fm1probe devices`, then choose one with --device")
    }
    if answering == 0 { exit(1) }
}

/// The ports that look like an FM-1, or the ones `--port` names; stops fm1probe if there are none.
private func portsToIdentify(_ transport: CoreMIDITransport) async throws -> [MIDIPortDescriptor] {
    let wanted = option("--port")
    let ports = await transport.ports().filter { port in
        wanted.map { wanted in
            [port.name, port.usbProductName].contains { $0?.localizedCaseInsensitiveContains(wanted) == true }
        } ?? FM1Updater.isProbeable(port)
    }
    guard ports.isEmpty else { return ports }
    let message =
        wanted.map { "No port matches \"\($0)\"." }
        ?? "No port looks like an FM-1. Run `fm1probe ports`, then try --port NAME."
    if isJSON {
        printJSON(ErrorJSON(format: "fm1probe-identify-1", file: nil, error: message))
    } else {
        print(message)
    }
    exit(1)
}

/// What one port answered.
private struct Answers {
    var times: [Double] = []
    var identities: Set<String> = []
    var firstReply: [UInt8]?

    var timing: Timing? { times.isEmpty ? nil : Timing(times) }

    /// The answers as `identify --json` gives them.
    func json(port: MIDIPortDescriptor, attempts: Int) -> IdentifyJSON.Port {
        let running: String? =
            if identities.isEmpty {
                nil
            } else if identities.contains(where: { FM1Identity(text: $0)?.isLoader == true }) {
                "updateLoader"
            } else {
                "firmware"
            }
        return IdentifyJSON.Port(
            port: PortJSON(port),
            attempts: attempts,
            answered: times.count,
            reply: firstReply.map(hex),
            identities: identities.sorted(),
            running: running,
            flashChip: firstReply.flatMap(FM1Identity.flashChipID(inHandshakeReply:)).map(FlashChipJSON.init),
            replyMilliseconds: timing.map { timing in
                IdentifyJSON.Timing(average: timing.average, fastest: timing.fastest, slowest: timing.slowest)
            }
        )
    }
}

/// Sends the handshake query `repeats` times, printing the first reply as it comes.
private func ask(_ connection: any MIDIConnection, repeats: Int) async -> Answers {
    var answers = Answers()
    for attempt in 1...repeats {
        if let answer = await handshake(connection) {
            if answers.firstReply == nil {
                answers.firstReply = answer.reply
                if !isJSON {
                    print("  reply: \(hex(answer.reply))")
                    if let chip = FM1Identity.flashChipID(inHandshakeReply: answer.reply) {
                        print("  flash chip: " + flashChipDescription(chip))
                    }
                }
            }
            answers.times.append(milliseconds(answer.elapsed))
            answers.identities.insert(answer.identity.text)
        } else if repeats > 1, !isJSON {
            print("  attempt \(attempt): no answer")
        }
        if repeats > 1 { try? await Task.sleep(for: .milliseconds(200)) }
    }
    connection.close()
    return answers
}

/// Prints what a port reported and how quickly.
private func printAnswers(_ answers: Answers, attempts: Int) {
    guard let timing = answers.timing else {
        print("  no answer")
        return
    }
    for text in answers.identities.sorted() {
        let isLoader = FM1Identity(text: text)?.isLoader == true
        print("  reports: \(text)  (\(isLoader ? "update loader: mid-update or USB recovery" : "firmware running"))")
    }
    if answers.identities.count > 1 { print("  warning: the answers disagreed") }
    print("  answered \(answers.times.count) of \(attempts); reply time \(timing.average) ms", terminator: "")
    print(" (fastest \(timing.fastest), slowest \(timing.slowest))")
}

/// Reply times in whole milliseconds.
private struct Timing {
    let average: Int
    let fastest: Int
    let slowest: Int

    init(_ times: [Double]) {
        average = Int((times.reduce(0, +) / Double(times.count)).rounded())
        fastest = Int((times.min() ?? 0).rounded())
        slowest = Int((times.max() ?? 0).rounded())
    }
}
