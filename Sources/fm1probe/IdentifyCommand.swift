import FM1Kit
import Foundation

/// Runs `identify`: asks each port that looks like an FM-1, or the one `--port` names, what it's
/// running, `--repeat` times, and reports the answers and how long they took.
func identify() async throws {
    let transport = try CoreMIDITransport(clientName: "fm1probe")
    let repeats = max(option("--repeat").flatMap(Int.init) ?? 1, 1)
    let wanted = option("--port")
    let ports = await transport.ports().filter { port in
        wanted.map { wanted in
            [port.name, port.usbProductName].contains { $0?.localizedCaseInsensitiveContains(wanted) == true }
        } ?? FM1Updater.isProbeable(port)
    }
    if ports.isEmpty {
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
    var results: [IdentifyJSON.Port] = []
    for port in ports {
        if !isJSON {
            print("\(portLabel(port)):")
            if let serial = port.serialNumber { print("  serial: \(serial)") }
        }
        let connection = try await transport.open(port)
        var times: [Double] = []
        var identities: Set<String> = []
        var firstReply: [UInt8]?
        for attempt in 1...repeats {
            if let answer = await handshake(connection) {
                if firstReply == nil {
                    firstReply = answer.reply
                    if !isJSON {
                        print("  reply: \(hex(answer.reply))")
                        if let chip = FM1Identity.flashChipID(inHandshakeReply: answer.reply) {
                            print("  flash chip: " + flashChipDescription(chip))
                        }
                    }
                }
                times.append(milliseconds(answer.elapsed))
                identities.insert(answer.identity.text)
            } else if repeats > 1, !isJSON {
                print("  attempt \(attempt): no answer")
            }
            if repeats > 1 { try? await Task.sleep(for: .milliseconds(200)) }
        }
        connection.close()
        let timing = times.isEmpty ? nil : Timing(times)
        results.append(
            IdentifyJSON.Port(
                port: PortJSON(port),
                attempts: repeats,
                answered: times.count,
                reply: firstReply.map(hex),
                identities: identities.sorted(),
                isUpdateLoader: identities.isEmpty
                    ? nil : identities.contains { FM1Identity(text: $0)?.isLoader == true },
                flashChip: firstReply.flatMap(FM1Identity.flashChipID(inHandshakeReply:)).map(FlashChipJSON.init),
                replyMilliseconds: timing.map {
                    IdentifyJSON.Timing(average: $0.average, fastest: $0.fastest, slowest: $0.slowest)
                }
            ))
        guard !isJSON else { continue }
        guard let timing else {
            print("  no answer")
            continue
        }
        for text in identities.sorted() {
            let isLoader = FM1Identity(text: text)?.isLoader == true
            print(
                "  reports: \(text)  (\(isLoader ? "update loader: mid-update or USB recovery" : "firmware running"))")
        }
        if identities.count > 1 { print("  warning: the answers disagreed") }
        print("  answered \(times.count) of \(repeats); reply time \(timing.average) ms", terminator: "")
        print(" (fastest \(timing.fastest), slowest \(timing.slowest))")
    }
    let answering = results.filter { $0.answered > 0 }.count
    if isJSON {
        printJSON(IdentifyJSON(ports: results))
    } else if answering > 1 {
        print("\(answering) FM-1s answered: run `fm1probe devices`, then choose one with --device")
    }
    if answering == 0 { exit(1) }
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
