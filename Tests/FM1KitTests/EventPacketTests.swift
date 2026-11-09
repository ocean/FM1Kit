import CoreMIDI
import Testing

@_spi(Testing) @testable import FM1Kit

/// Reading SysEx out of CoreMIDI's event packets.
struct EventPacketTests {
    /// A 512-byte response in one event packet longer than the 64 words `MIDIEventPacket` declares,
    /// as CoreMIDI hands packets from one app to another.
    @Test func readsPacketsLongerThanSixtyFourWords() throws {
        let message = FM1ReadRequest(address: 0x4000, length: 512).response(with: [UInt8](repeating: 0x3C, count: 512))
        let words = UMPSysex7.packets(for: message).flatMap { [$0.0, $0.1] }
        #expect(words.count > 64)
        let offset = try #require(MemoryLayout<MIDIEventPacket>.offset(of: \.words))
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: offset + words.count * MemoryLayout<UInt32>.stride,
            alignment: MemoryLayout<MIDIEventPacket>.alignment)
        defer { buffer.deallocate() }
        let packet = buffer.bindMemory(to: MIDIEventPacket.self, capacity: 1)
        packet.pointee.timeStamp = 0
        packet.pointee.wordCount = UInt32(words.count)
        (buffer + offset).bindMemory(to: UInt32.self, capacity: words.count)
            .update(from: words, count: words.count)
        #expect(AssemblerBox().consume(UnsafePointer(packet)) == [message])
    }
}
