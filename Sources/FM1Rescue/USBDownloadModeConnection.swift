#if os(macOS)
import Foundation
import IOKit
import IOUSBHost

/// A real FM-1 in download mode, over USB, on a Mac.
///
/// In download mode the chip shows up as a USB disk (`4C4A:8057`), which macOS's disk driver
/// claims. Opening a connection captures the device from that driver, which needs root, then
/// speaks USB mass storage's Bulk-Only Transport to it directly, as M-Flasher does with libusb.
/// macOS may ask once to allow access to a removable volume. When the connection closes, the
/// device is left without a driver, still in download mode, until it's switched off.
public final class USBDownloadModeConnection: DownloadModeConnection {
    /// The chip's USB vendor ID in download mode.
    public static let vendorID = 0x4C4A
    /// The chip's USB product ID in download mode.
    public static let productID = 0x8057

    private let device: IOUSBHostDevice
    private let interface: IOUSBHostInterface
    private let inPipe: IOUSBHostPipe
    private let outPipe: IOUSBHostPipe
    private let interfaceNumber: UInt16
    private var tag: UInt32 = 0
    private var isClosed = false

    /// Called with a line for every USB transfer, for diagnosing a device that misbehaves.
    public var trace: ((String) -> Void)?

    /// How long one transfer may take.
    static let timeout: TimeInterval = 10
    /// What IOUSBHost reports when an endpoint stalls (`kUSBHostReturnPipeStalled`), and the older
    /// USB family's code for it (`kIOUSBPipeStalled`).
    static let pipeStalledCodes = [Int(Int32(bitPattern: 0xE000_5000)), Int(Int32(bitPattern: 0xE000_404F))]
    /// How many leftover status blocks from earlier commands are skipped before giving up.
    static let staleStatusLimit = 8

    /// How many devices are in download mode now; this needs no special rights.
    public static func deviceCount() -> Int {
        let services = matchingServices()
        for service in services {
            IOObjectRelease(service)
        }
        return services.count
    }

    /// Captures the only device in download mode from macOS's disk driver.
    ///
    /// - Returns: The open connection; close it when finished.
    /// - Throws: ``DownloadModeError/notFound``, ``DownloadModeError/multipleDevices(count:)``,
    ///   ``DownloadModeError/needsRoot`` when not run as root, or
    ///   ``DownloadModeError/accessRefused(_:)`` when macOS refuses.
    public static func open() throws(DownloadModeError) -> USBDownloadModeConnection {
        let services = matchingServices()
        guard let service = services.first else { throw .notFound }
        for other in services.dropFirst() {
            IOObjectRelease(other)
        }
        guard services.count == 1 else {
            IOObjectRelease(service)
            throw .multipleDevices(count: services.count)
        }
        guard geteuid() == 0 else {
            IOObjectRelease(service)
            throw .needsRoot
        }
        // The device object keeps the service and releases it when it's destroyed.
        let device: IOUSBHostDevice
        do {
            device = try IOUSBHostDevice(
                __ioService: service, options: [.deviceCapture], queue: nil, interestHandler: nil)
        } catch {
            throw .accessRefused(describe(error))
        }
        // Capturing ends the disk driver's hold on the interface, which takes a moment.
        var lastError: DownloadModeError = .accessRefused("the mass-storage interface didn't appear")
        for _ in 0..<20 {
            do {
                return try USBDownloadModeConnection(device: device, service: service)
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        device.destroy(options: [.deviceSurrender])
        throw lastError
    }

    /// Opens the device's mass-storage interface and its two bulk endpoints.
    private init(device: IOUSBHostDevice, service: io_service_t) throws(DownloadModeError) {
        guard let interfaceService = Self.massStorageInterface(of: service) else {
            throw .accessRefused("no mass-storage interface")
        }
        let interface: IOUSBHostInterface
        do {
            interface = try IOUSBHostInterface(
                __ioService: interfaceService, options: [], queue: nil, interestHandler: nil)
        } catch {
            IOObjectRelease(interfaceService)
            throw .accessRefused(Self.describe(error))
        }
        var endpoints: (in: Int?, out: Int?) = (nil, nil)
        var current: UnsafePointer<IOUSBEndpointDescriptor>?
        while true {
            current = IOUSBGetNextEndpointDescriptor(
                interface.configurationDescriptor,
                interface.interfaceDescriptor,
                UnsafeRawPointer(current)?.assumingMemoryBound(to: IOUSBDescriptorHeader.self)
            )
            guard let endpoint = current?.pointee else { break }
            // Bulk endpoints only; bit 7 of the address marks one that sends to the host.
            guard endpoint.bmAttributes & 0x03 == 0x02 else { continue }
            if endpoint.bEndpointAddress & 0x80 != 0 {
                endpoints.in = Int(endpoint.bEndpointAddress)
            } else {
                endpoints.out = Int(endpoint.bEndpointAddress)
            }
        }
        guard let inAddress = endpoints.in, let outAddress = endpoints.out else {
            interface.destroy()
            throw .accessRefused("no bulk endpoints")
        }
        do {
            inPipe = try interface.copyPipe(withAddress: inAddress)
            outPipe = try interface.copyPipe(withAddress: outAddress)
        } catch {
            interface.destroy()
            throw .accessRefused(Self.describe(error))
        }
        self.device = device
        self.interface = interface
        interfaceNumber = UInt16(interface.interfaceDescriptor.pointee.bInterfaceNumber)
    }

    deinit {
        close()
    }

    /// Sends one command over Bulk-Only Transport and runs its data phase.
    ///
    /// - Parameters:
    ///   - command: The command block.
    ///   - phase: Which way data moves after the command, if at all.
    /// - Returns: The bytes received.
    /// - Throws: ``DownloadModeError/commandFailed(_:)`` or ``DownloadModeError/transferFailed(_:)``.
    public func execute(_ command: [UInt8], _ phase: DataPhase) throws(DownloadModeError) -> [UInt8] {
        guard !isClosed else { throw .transferFailed("the connection is closed") }
        do {
            return try transfer(command, phase)
        } catch {
            // A refused command leaves the transport in order; anything else is reset.
            if case .transferFailed = error { resetRecovery() }
            throw error
        }
    }

    /// Lets go of the device without resetting it, so it stays in download mode, without a driver,
    /// until it's switched off.
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        interface.destroy()
        // Without a reset, so the chip stays in download mode until it's switched off.
        device.destroy(options: [.deviceSurrender])
    }

    // MARK: - Bulk-Only Transport.

    /// Sends a command block wrapper, runs the data phase, then reads the status wrapper.
    private func transfer(_ command: [UInt8], _ phase: DataPhase) throws(DownloadModeError) -> [UInt8] {
        tag &+= 1
        let name = String(format: "0x%02x%02x", command[0], command.count > 1 ? command[1] : 0)
        let wrapper = Self.commandWrapper(command, phase, tag: tag)
        trace?("CBW tag \(tag): \(Self.hex(command)), \(phase.traceDescription)")
        _ = try send(wrapper, on: outPipe, what: "sending command \(name)")

        var received: [UInt8] = []
        switch phase {
        case .noData, .receive(0), .send([]):
            break
        case .receive(let count):
            let data = try receive(count, on: inPipe, what: "command \(name): reading its data")
            received = data ?? []
            trace?(data.map { "  data in: \($0.count) bytes: \(Self.hex($0.prefix(32)))" } ?? "  data in: stalled")
        case .send(let bytes):
            let sent = try send(bytes, on: outPipe, what: "command \(name): sending its data")
            trace?(sent.map { "  data out: \($0) bytes" } ?? "  data out: stalled")
            if let sent, sent != bytes.count {
                throw .transferFailed("command \(name): \(sent) of \(bytes.count) bytes sent")
            }
        }
        try readStatus(of: name)
        return received
    }

    /// The 31-byte command block wrapper.
    static func commandWrapper(_ command: [UInt8], _ phase: DataPhase, tag: UInt32) -> [UInt8] {
        var wrapper = [UInt8](repeating: 0, count: 31)
        var length = 0
        switch phase {
        case .noData: break
        case .receive(let count):
            length = count
            wrapper[12] = 0x80
        case .send(let bytes): length = bytes.count
        }
        wrapper.replaceSubrange(0..<4, with: littleEndian(0x4342_5355))  // "USBC"
        wrapper.replaceSubrange(4..<8, with: littleEndian(tag))
        wrapper.replaceSubrange(8..<12, with: littleEndian(UInt32(length)))
        wrapper[14] = UInt8(command.count)
        wrapper.replaceSubrange(15..<(15 + command.count), with: command)
        return wrapper
    }

    /// Reads the 13-byte command status wrapper, and throws unless the command succeeded.
    private func readStatus(of name: String) throws(DownloadModeError) {
        let what = "command \(name): reading its status"
        var reply = try receive(13, on: inPipe, what: what)
        if reply == nil {
            trace?("  status: stalled, trying again")
            // The status endpoint stalled and has been cleared, so try once more.
            reply = try receive(13, on: inPipe, what: what)
        }
        var status = reply ?? []
        trace?("  status: \(status.count) bytes: \(Self.hex(status))")
        // A status block left over from an earlier command that failed part-way is skipped.
        var skipped = 0
        while Self.isStaleStatus(status, expecting: tag), skipped < Self.staleStatusLimit {
            skipped += 1
            reply = try receive(13, on: inPipe, what: what)
            status = reply ?? []
            trace?("  status (after skipping a stale one): \(status.count) bytes: \(Self.hex(status))")
        }
        guard
            status.count == 13, Self.readLittleEndian(status, at: 0) == 0x5342_5355,  // "USBS"
            Self.readLittleEndian(status, at: 4) == tag
        else {
            let got = reply == nil ? "a stall" : "\(status.count) bytes: \(Self.hex(status.prefix(16)))"
            throw .transferFailed("command \(name): an invalid status block, \(got), tag \(tag) expected")
        }
        switch status[12] {
        case 0: return
        case 1: throw .commandFailed("command \(name)")
        default: throw .transferFailed("command \(name): phase error \(status[12])")
        }
    }

    /// Sends bytes; returns how many went, or `nil` when the endpoint stalled (and was cleared).
    private func send(_ bytes: [UInt8], on pipe: IOUSBHostPipe, what: String) throws(DownloadModeError) -> Int? {
        let data = NSMutableData(bytes: bytes, length: bytes.count)
        return try request(data, on: pipe, what: what)
    }

    /// Receives up to `count` bytes, or `nil` when the endpoint stalled (and was cleared).
    private func receive(_ count: Int, on pipe: IOUSBHostPipe, what: String) throws(DownloadModeError) -> [UInt8]? {
        guard let data = NSMutableData(length: count) else { throw .transferFailed(what) }
        guard let moved = try request(data, on: pipe, what: what) else { return nil }
        return [UInt8](Data(referencing: data).prefix(moved))
    }

    private func request(_ data: NSMutableData, on pipe: IOUSBHostPipe, what: String) throws(DownloadModeError)
        -> Int?
    {
        var moved = 0
        do {
            try pipe.__sendIORequest(with: data, bytesTransferred: &moved, completionTimeout: Self.timeout)
            return moved
        } catch {
            guard Self.pipeStalledCodes.contains((error as NSError).code) else {
                trace?("  \(what): \(Self.describe(error))")
                throw .transferFailed("\(what): \(Self.describe(error))")
            }
            try? pipe.clearStall()
            return nil
        }
    }

    /// Bulk-Only Mass Storage Reset, then clears both endpoints' stalls.
    private func resetRecovery() {
        trace?("  reset recovery")
        var request = IOUSBDeviceRequest()
        request.bmRequestType = 0x21
        request.bRequest = 0xFF
        request.wIndex = interfaceNumber
        try? interface.__send(request, data: nil, bytesTransferred: nil, completionTimeout: Self.timeout)
        try? inPipe.clearStall()
        try? outPipe.clearStall()
    }

    // MARK: - Finding the device.

    /// Every USB device in the chip's download mode.
    private static func matchingServices() -> [io_service_t] {
        // swiftlint:disable legacy_objc_type
        // IOUSBHost's matching takes NSNumbers.
        let matching = IOUSBHostDevice.__createMatchingDictionary(
            withVendorID: NSNumber(value: vendorID),
            productID: NSNumber(value: productID),
            bcdDevice: nil,
            deviceClass: nil,
            deviceSubclass: nil,
            deviceProtocol: nil,
            speed: nil,
            productIDArray: nil
        )
        .takeRetainedValue()
        // swiftlint:enable legacy_objc_type
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var services: [io_service_t] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            services.append(service)
        }
        return services
    }

    /// The device's mass-storage interface (class 8), if it has one.
    private static func massStorageInterface(of device: io_service_t) -> io_service_t? {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(device, kIOServicePlane, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        while case let child = IOIteratorNext(iterator), child != 0 {
            let property = IORegistryEntryCreateCFProperty(
                child, "bInterfaceClass" as CFString, kCFAllocatorDefault, 0)
            if IOObjectConformsTo(child, "IOUSBHostInterface") != 0,
                property?.takeRetainedValue() as? Int == 8
            {
                return child
            }
            IOObjectRelease(child)
        }
        return nil
    }

    static func describe(_ error: any Error) -> String {
        let error = error as NSError
        return String(format: "0x%08x, ", UInt32(truncatingIfNeeded: error.code)) + error.localizedDescription
    }

    /// True for a well-formed status block whose tag is from an earlier command.
    static func isStaleStatus(_ status: [UInt8], expecting tag: UInt32) -> Bool {
        guard status.count == 13, readLittleEndian(status, at: 0) == 0x5342_5355 else { return false }
        let earlier = tag &- readLittleEndian(status, at: 4)
        return earlier > 0 && earlier <= UInt32(staleStatusLimit)
    }

    static func hex(_ bytes: some Collection<UInt8>) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    static func littleEndian(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }

    static func readLittleEndian(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
    }
}

extension DataPhase {
    fileprivate var traceDescription: String {
        switch self {
        case .noData: "no data"
        case .receive(let count): "receive \(count)"
        case .send(let bytes): "send \(bytes.count)"
        }
    }
}
#endif
