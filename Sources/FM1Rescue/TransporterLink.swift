#if os(macOS)
import Foundation
import IOKit
import IOKit.serial

/// A byte stream to the FM-1 Transporter's data port, real or simulated.
public protocol TransporterLink: AnyObject {
    /// Sends bytes.
    ///
    /// - Parameter bytes: The bytes.
    /// - Throws: ``TransporterError/portFailed(_:_:)`` when they can't be sent.
    func send(_ bytes: [UInt8]) throws(TransporterError)

    /// Waits for bytes.
    ///
    /// - Parameter timeout: How long to wait.
    /// - Returns: The bytes that arrived, or none when none did in time.
    /// - Throws: ``TransporterError/portFailed(_:_:)`` when the port fails.
    func receive(timeout: Duration) throws(TransporterError) -> [UInt8]

    /// Closes the link.
    func close()
}

/// The FM-1 Transporter's data port, a USB serial port.
public final class SerialTransporterLink: TransporterLink {
    /// The port's path, such as `/dev/cu.usbmodem21103`.
    public let path: String
    private var descriptor: Int32

    /// The name the Transporter gives itself on USB.
    static let productName = "FM-1 Transporter"

    /// Opens a serial port.
    ///
    /// - Parameter path: The port's path.
    /// - Throws: ``TransporterError/portFailed(_:_:)`` when it can't be opened.
    public init(path: String) throws(TransporterError) {
        self.path = path
        descriptor = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard descriptor >= 0 else { throw .portFailed(path, String(cString: strerror(errno))) }
        var settings = termios()
        tcgetattr(descriptor, &settings)
        cfmakeraw(&settings)
        cfsetspeed(&settings, speed_t(B115200))
        settings.c_cflag |= tcflag_t(CLOCAL | CREAD)
        guard tcsetattr(descriptor, TCSANOW, &settings) == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(descriptor)
            throw .portFailed(path, reason)
        }
    }

    deinit {
        close()
    }

    /// Finds the Transporter's data port and opens it.
    ///
    /// The Transporter has two serial ports, a log console and the data port. Each of its ports
    /// is asked `ping`, and the one that answers `PONG` is the data port.
    ///
    /// - Parameter path: A port to use instead of looking.
    /// - Returns: The open data port.
    /// - Throws: ``TransporterError/notFound`` when no port answers.
    public static func find(path: String? = nil) throws(TransporterError) -> SerialTransporterLink {
        for candidate in path.map({ [$0] }) ?? transporterPorts() {
            guard let link = try? SerialTransporterLink(path: candidate) else { continue }
            if (try? link.answersPing()) == true { return link }
            link.close()
        }
        throw .notFound
    }

    /// The serial ports of every connected FM-1 Transporter, by the name it gives itself on USB.
    static func transporterPorts() -> [String] {
        var iterator: io_iterator_t = 0
        guard
            IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOSerialBSDServiceValue), &iterator)
                == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        var ports: [String] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
            let product = ["USB Product Name", "kUSBProductString"].lazy.compactMap { key in
                IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, nil, options) as? String
            }.first
            guard product == productName,
                let callout = IORegistryEntryCreateCFProperty(
                    service, kIOCalloutDeviceKey as CFString, nil, 0)?.takeRetainedValue() as? String
            else { continue }
            ports.append(callout)
        }
        return ports.sorted()
    }

    /// Asks `ping` and waits a second and a half for `PONG`, which only the data port answers.
    private func answersPing() throws(TransporterError) -> Bool {
        _ = try receive(timeout: .zero)
        try send(Array("ping\n".utf8))
        var answer: [UInt8] = []
        let deadline = ContinuousClock.now + .milliseconds(1500)
        while ContinuousClock.now < deadline {
            answer += try receive(timeout: deadline - ContinuousClock.now)
            if String(bytes: answer, encoding: .utf8)?.contains("PONG\n") == true { return true }
        }
        return false
    }

    /// Sends bytes to the port.
    public func send(_ bytes: [UInt8]) throws(TransporterError) {
        var sent = 0
        while sent < bytes.count {
            let count = bytes[sent...].withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EAGAIN {
                var poller = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                poll(&poller, 1, 1000)
                continue
            }
            guard count > 0 else { throw .portFailed(path, String(cString: strerror(errno))) }
            sent += count
        }
    }

    /// Waits for bytes from the port.
    public func receive(timeout: Duration) throws(TransporterError) -> [UInt8] {
        var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let (seconds, attoseconds) = timeout.components
        let milliseconds = Int32(clamping: max(seconds * 1000 + attoseconds / 1_000_000_000_000_000, 0))
        let ready = poll(&poller, 1, milliseconds)
        guard ready > 0 else {
            if ready < 0, errno != EINTR { throw .portFailed(path, String(cString: strerror(errno))) }
            return []
        }
        guard poller.revents & Int16(POLLIN) != 0 else {
            throw .portFailed(path, "the port closed: the Transporter was unplugged or restarted")
        }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let count = read(descriptor, &buffer, buffer.count)
        guard count >= 0 else {
            if errno == EAGAIN { return [] }
            throw .portFailed(path, String(cString: strerror(errno)))
        }
        return Array(buffer[0..<count])
    }

    /// Closes the port.
    public func close() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }
}
#endif
