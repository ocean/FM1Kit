import Foundation
import Testing
import os

@testable import FM1Kit

struct PackageEdgeCaseTests {
    @Test func rejectsPackagesForOtherModels() {
        let file = FwscPackage.encode(logicalImage: [UInt8](repeating: 1, count: 2000), product: "FM-2_5")
        #expect(throws: FwscPackage.Failure.unexpectedModel("FM-2")) { try FwscPackage(bytes: file) }
    }

    @Test func rejectsUnreadableIdentities() {
        let file = FwscPackage.encode(logicalImage: [UInt8](repeating: 1, count: 2000), product: "FM-1_abc")
        #expect(throws: FwscPackage.Failure.unreadableProduct("FM-1_abc")) { try FwscPackage(bytes: file) }
    }

    @Test func hashesTheFileNotTheImage() throws {
        #expect(
            FwscPackage.sha256Hex(Data("abc".utf8))
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let package = try UpdaterTests.package()
        #expect(package.sha256 == FwscPackage.sha256Hex(package.fileBytes))
        #expect(package.sha256 != FwscPackage.sha256Hex(package.logicalImage))
        #expect(package.logicalImage.count == package.fileBytes.count - FwscPackage.blockCount)
    }

    @Test func recognisesOnlyOfficialReleases() throws {
        #expect(OfficialFirmware.known.contains(.v15))
        #expect(OfficialFirmware.matching(try UpdaterTests.package()) == nil)
    }
}

struct IdentityEdgeCaseTests {
    @Test(arguments: ["_5", "FM-1_", "FM-1_12a", "FM-1", "", "FM-1_１２", "FM-1_-5", "FM-1_+5", "FM 1_5", "FM-1_5\n"])
    func rejectsMalformedText(_ text: String) {
        #expect(FM1Identity(text: text) == nil)
    }

    @Test func splitsAtTheLastUnderscore() throws {
        let identity = try #require(FM1Identity(text: "My_FM-1_42"))
        #expect(identity.model == "My_FM-1")
        #expect(identity.version == 42)
        #expect(!identity.isLoader)
        #expect(identity.hardwareModel == "My_FM-1")
        #expect(identity.description == "My_FM-1_42")
    }

    @Test func ignoresRepliesThatAreNotHandshakes() throws {
        let reply = try #require(FM1Identity(text: "FM-1_916")).handshakeReply()
        #expect(FM1Identity(handshakeReply: Array(reply.dropLast())) == nil)
        #expect(FM1Identity(handshakeReply: Array(reply.prefix(20)) + [0xF7]) == nil)
        #expect(FM1Identity(handshakeReply: FM1Message.handshakeQuery) == nil)
        #expect(FM1Identity(handshakeReply: FM1ReadRequest(address: 0, length: 16).encoded()) == nil)
    }
}

struct MessageEdgeCaseTests {
    @Test func finishRequestsAreAnsweredWithSuccess() throws {
        for address in [FM1Message.stageFinishAddress, FM1Message.writeFinishAddress] {
            let request = FM1ReadRequest(address: address, length: 8)
            #expect(request.isFinish)
            let parsed = try #require(FM1ReadRequest.parseResponse(request.finishResponse()))
            #expect(parsed.data == Array("success".utf8) + [0])
        }
        #expect(!FM1ReadRequest(address: 0x1000, length: 8).isFinish)
    }

    @Test func otherMessagesAreNotReadRequests() {
        #expect(FM1ReadRequest(sysex: FM1Message.handshakeQuery) == nil)
        #expect(FM1ReadRequest(sysex: FM1Message.upgradeCommand) == nil)
        #expect(FM1ReadRequest(sysex: []) == nil)
        let request = FM1ReadRequest(address: 0x200, length: 64).encoded()
        #expect(FM1ReadRequest(sysex: Array(request.dropLast())) == nil)
        // A response is longer than a request, so it isn't mistaken for one.
        #expect(FM1ReadRequest(sysex: FM1ReadRequest(address: 0x200, length: 4).response(with: [1, 2, 3, 4])) == nil)
    }

    @Test func responsesWithAWrongLengthOrChecksumAreRejected() {
        let response = FM1ReadRequest(address: 0x40, length: 16).response(with: [UInt8](repeating: 7, count: 16))
        var body = SevenBit.unpack(response.dropFirst().dropLast())
        body[body.count - 2] ^= 0x01
        #expect(FM1ReadRequest.parseResponse(FM1Message.frame(Array(body))) == nil)
        #expect(FM1ReadRequest.parseResponse(Array(response.prefix(response.count - 3)) + [0xF7]) == nil)
    }
}

struct UMPEdgeCaseTests {
    @Test func ignoresContinuationsWithoutAStart() {
        let message = FM1ReadRequest(address: 0, length: 64).response(with: [UInt8](repeating: 0x11, count: 64))
        let packets = UMPSysex7.packets(for: message)
        var assembler = UMPSysex7.Assembler()
        for (word0, word1) in packets.dropFirst() {
            #expect(assembler.consume(word0, word1) == nil)
        }
        var result: [UInt8]?
        for (word0, word1) in packets {
            result = assembler.consume(word0, word1) ?? result
        }
        #expect(result == message)
    }

    @Test func aNewStartDiscardsAnUnfinishedMessage() {
        let first = UMPSysex7.packets(for: [UInt8](repeating: 0x22, count: 30))
        let second = [0xF0] + [UInt8](repeating: 0x33, count: 20) + [0xF7]
        var assembler = UMPSysex7.Assembler()
        _ = assembler.consume(first[0].0, first[0].1)
        _ = assembler.consume(first[1].0, first[1].1)
        var result: [UInt8]?
        for (word0, word1) in UMPSysex7.packets(for: second) {
            result = assembler.consume(word0, word1) ?? result
        }
        #expect(result == second)
    }

    @Test func dropsMessagesThatNeverEnd() {
        let long = [UInt8](repeating: 0x44, count: UMPSysex7.Assembler.maximumMessageLength + 12)
        var packets = UMPSysex7.packets(for: long)
        let end = packets.removeLast()
        var assembler = UMPSysex7.Assembler()
        for (word0, word1) in packets {
            #expect(assembler.consume(word0, word1) == nil)
        }
        #expect(assembler.consume(end.0, end.1) == nil)
    }

    @Test func ignoresOtherMessageTypes() {
        var assembler = UMPSysex7.Assembler()
        // A MIDI 1.0 channel voice message (type 2): note on.
        #expect(assembler.consume(0x2090_3C64, 0) == nil)
        #expect(UMPSysex7.wordCount(forFirstWord: 0x2090_3C64) == 1)
        #expect(UMPSysex7.wordCount(forFirstWord: 0x4090_3C00) == 2)
        #expect(UMPSysex7.wordCount(forFirstWord: 0xF000_0000) == 4)
    }
}

struct SysexInboxTests {
    @Test func deliversInOrder() async {
        let inbox = SysexInbox()
        inbox.deliver([1])
        inbox.deliver([2])
        #expect(await inbox.next(timeout: .milliseconds(50)) == [1])
        #expect(await inbox.next(timeout: .milliseconds(50)) == [2])
    }

    @Test func timesOut() async {
        let inbox = SysexInbox()
        #expect(await inbox.next(timeout: .milliseconds(30)) == nil)
        inbox.deliver([3])
        #expect(await inbox.next(timeout: .milliseconds(30)) == [3])
    }

    @Test func wakesAWaiterWhenAMessageArrives() async {
        let inbox = SysexInbox()
        async let waiting = inbox.next(timeout: .seconds(5))
        try? await Task.sleep(for: .milliseconds(30))
        inbox.deliver([4])
        #expect(await waiting == [4])
    }

    @Test func closingWakesTheWaiterAndIgnoresLaterMessages() async {
        let inbox = SysexInbox()
        async let waiting = inbox.next(timeout: .seconds(5))
        try? await Task.sleep(for: .milliseconds(30))
        inbox.close()
        #expect(await waiting == nil)
        inbox.deliver([5])
        #expect(await inbox.next(timeout: .milliseconds(30)) == nil)
    }

    @Test func drainDiscardsQueuedMessages() async {
        let inbox = SysexInbox()
        inbox.deliver([6])
        inbox.drain()
        #expect(await inbox.next(timeout: .milliseconds(30)) == nil)
    }
}

/// A transport with fixed ports that records which ones were opened, and never answers.
final class SilentTransport: MIDITransport, @unchecked Sendable {
    let available: [MIDIPortDescriptor]
    let opened = OSAllocatedUnfairLock(initialState: [String]())

    init(ports: [MIDIPortDescriptor]) {
        available = ports
    }

    func ports() async -> [MIDIPortDescriptor] { available }

    func open(_ port: MIDIPortDescriptor) async throws -> any MIDIConnection {
        opened.withLock { $0.append(port.name) }
        return SilentConnection(port: port)
    }

    func changes() -> AsyncStream<Void> { AsyncStream { _ in } }
}

final class SilentConnection: MIDIConnection, @unchecked Sendable {
    let port: MIDIPortDescriptor
    let sent = OSAllocatedUnfairLock(initialState: [[UInt8]]())
    var isLost: Bool { false }

    init(port: MIDIPortDescriptor) {
        self.port = port
    }

    func send(_ sysex: [UInt8]) throws { sent.withLock { $0.append(sysex) } }
    func receive(timeout: Duration) async -> [UInt8]? {
        try? await Task.sleep(for: timeout)
        return nil
    }
    func drain() {}
    func close() {}
}

struct UpdaterEdgeCaseTests {
    @Test(arguments: [
        ("FM-1 Midi", true), ("FM1", true), ("ota-FM-1", true), ("USB-MIDI", true),
        ("IAC Driver Bus 1", false), ("Arturia KeyStep 37", false), ("Network Session 1", false),
    ])
    func probesOnlyPortsThatLookLikeAnFM1(name: String, probeable: Bool) {
        #expect(FM1Updater.isProbeable(MIDIPortDescriptor(id: name, name: name)) == probeable)
    }

    @Test func neverSendsToOtherGear() async throws {
        let transport = SilentTransport(ports: [
            MIDIPortDescriptor(id: "a", name: "Arturia KeyStep 37"),
            MIDIPortDescriptor(id: "b", name: "FM-1 Midi"),
        ])
        let updater = FM1Updater(transport: transport, timing: UpdaterTests.fastTiming)
        #expect(await updater.identify() == nil)
        #expect(transport.opened.withLock { $0 } == ["FM-1 Midi"])
        await #expect(throws: FM1UpdateError.deviceNotFound) { try await updater.install(try UpdaterTests.package()) }
    }

    @Test func refusesAPackageForAnotherModel() async throws {
        var options = UpdaterTests.fastOptions
        options.installedIdentity = FM1Identity(model: "FM-2", version: 1)
        let updater = FM1Updater(transport: SimulatedFM1(options: options), timing: UpdaterTests.fastTiming)
        await #expect(throws: FM1UpdateError.modelMismatch(device: "FM-2_1", package: "FM-1_916")) {
            try await updater.install(try UpdaterTests.package())
        }
    }

    @Test func resumeNeedsTheLoader() async throws {
        let updater = FM1Updater(
            transport: SimulatedFM1(options: UpdaterTests.fastOptions), timing: UpdaterTests.fastTiming)
        await #expect(throws: FM1UpdateError.loaderNotFound) { try await updater.resume(try UpdaterTests.package()) }
    }

    @Test func reportsEachStepInOrder() async throws {
        let device = SimulatedFM1(options: UpdaterTests.fastOptions)
        let package = try UpdaterTests.package()
        device.prepare(for: package)
        let events = OSAllocatedUnfairLock(initialState: [UpdateEvent]())
        try await FM1Updater(transport: device, timing: UpdaterTests.fastTiming).install(package) { event in
            events.withLock { $0.append(event) }
        }
        let recorded = events.withLock { $0 }

        // Collapse repeated progress events to see the sequence of steps.
        let steps = recorded.map { event -> String in
            switch event {
            case .connected: "connected"
            case .staging: "staging"
            case .waitingForLoader: "waitingForLoader"
            case .loaderFound: "loaderFound"
            case .writing: "writing"
            case .checking: "checking"
            case .rebooting: "rebooting"
            case .finished: "finished"
            }
        }
        let collapsed = steps.reduce(into: [String]()) { if $0.last != $1 { $0.append($1) } }
        #expect(
            collapsed == [
                "connected", "staging", "waitingForLoader", "loaderFound", "writing", "rebooting", "finished",
            ])

        let fractions = recorded.compactMap { event -> Double? in
            if case .writing(let fraction, _) = event { return fraction }
            return nil
        }
        #expect(fractions == fractions.sorted())
        #expect(fractions.last == 1)
        #expect(recorded.last == .finished(package.identity))
    }
}

struct SysexInboxLimitTests {
    @Test func cancellingEndsTheWait() async {
        let inbox = SysexInbox()
        let start = ContinuousClock.now
        let waiting = Task { await inbox.next(timeout: .seconds(10)) }
        try? await Task.sleep(for: .milliseconds(30))
        waiting.cancel()
        #expect(await waiting.value == nil)
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func aWaitCancelledBeforeItStartsEndsAtOnce() async {
        let inbox = SysexInbox()
        let waiting = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await inbox.next(timeout: .seconds(10))
        }
        #expect(await waiting.value == nil)
    }

    @Test func keepsOnlyTheNewestMessagesWhenFull() async {
        let inbox = SysexInbox()
        for index in 0..<(SysexInbox.capacity + 3) {
            inbox.deliver([UInt8(truncatingIfNeeded: index)])
        }
        #expect(await inbox.next(timeout: .milliseconds(10)) == [3])
    }
}

struct IdentityCodingTests {
    @Test func storesAnIdentityAsItsText() throws {
        let identity = try #require(FM1Identity(text: "FM-1_916"))
        let data = try JSONEncoder().encode([identity])
        #expect(String(bytes: data, encoding: .utf8) == #"["FM-1_916"]"#)
        #expect(try JSONDecoder().decode([FM1Identity].self, from: data) == [identity])
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([FM1Identity].self, from: Data(#"["nope"]"#.utf8))
        }
    }
}

struct RefusedPackageTests {
    @Test func theRunningFirmwareIsRefusedWhileStaging() async throws {
        var options = UpdaterTests.fastOptions
        options.installedIdentity = FM1Identity(model: "FM-1", version: 916)
        let device = SimulatedFM1(options: options)
        let package = try UpdaterTests.package(product: "FM-1_916")
        device.prepare(for: package)
        let updater = FM1Updater(transport: device, timing: UpdaterTests.fastTiming)
        await #expect(throws: FM1UpdateError.stalled(phase: .staging, requests: options.stagingRequestCount)) {
            try await updater.install(package)
        }
        #expect(device.currentIdentity == package.identity)
    }
}
