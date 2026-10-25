import Foundation
import CLibUSB

/// A NetMD device visible on the USB bus (not necessarily opened).
public struct AttachedDevice: Equatable, Hashable, Sendable {
    public let definition: DeviceDefinition
    public let busNumber: UInt8
    public let address: UInt8
    public var name: String { definition.name }

    public static func == (l: AttachedDevice, r: AttachedDevice) -> Bool {
        l.busNumber == r.busNumber && l.address == r.address
            && l.definition.vendorId == r.definition.vendorId && l.definition.productId == r.definition.productId
    }
    public func hash(into h: inout Hasher) {
        h.combine(busNumber); h.combine(address); h.combine(definition.vendorId); h.combine(definition.productId)
    }
}

private func usbError(_ rc: Int32) -> String { String(cString: libusb_strerror(rc)) }

/// Thin libusb wrapper that implements the NetMD vendor control + bulk transport.
public final class NetMDTransport {
    private static let bulkWriteEndpoint: UInt8 = 0x02
    private static let bulkReadEndpoint: UInt8 = 0x81
    private static let controlTimeout: UInt32 = 5_000
    private static let bulkTimeout: UInt32 = 120_000
    private static let ctxLock = NSLock()
    nonisolated(unsafe) private static var sharedContext: OpaquePointer?

    private static func context() throws -> OpaquePointer {
        ctxLock.lock(); defer { ctxLock.unlock() }
        if let c = sharedContext { return c }
        var ctx: OpaquePointer?
        let rc = libusb_init(&ctx)
        guard rc == 0, let ctx else { throw NetMDError.usb("libusb_init failed: \(rc)") }
        sharedContext = ctx
        return ctx
    }

    public static func attachedDevices() -> [AttachedDevice] {
        guard let ctx = try? context() else { return [] }
        var list: UnsafeMutablePointer<OpaquePointer?>?
        let count = libusb_get_device_list(ctx, &list)
        guard count > 0, let list else { return [] }
        defer { libusb_free_device_list(list, 1) }
        var result: [AttachedDevice] = []
        for i in 0..<count {
            guard let dev = list[i] else { continue }
            var desc = libusb_device_descriptor()
            guard libusb_get_device_descriptor(dev, &desc) == 0 else { continue }
            if let def = knownDevices.first(where: { $0.vendorId == desc.idVendor && $0.productId == desc.idProduct }) {
                result.append(AttachedDevice(definition: def, busNumber: libusb_get_bus_number(dev), address: libusb_get_device_address(dev)))
            }
        }
        return result
    }

    public let device: AttachedDevice
    private var handle: OpaquePointer?
    private let interfaceNumber: Int32 = 0

    public init(device: AttachedDevice) throws {
        self.device = device
        let ctx = try Self.context()
        var list: UnsafeMutablePointer<OpaquePointer?>?
        let count = libusb_get_device_list(ctx, &list)
        guard count > 0, let list else { throw NetMDError.usb("No USB devices found") }
        defer { libusb_free_device_list(list, 1) }
        var found: OpaquePointer?
        for i in 0..<count {
            guard let dev = list[i] else { continue }
            if libusb_get_bus_number(dev) == device.busNumber && libusb_get_device_address(dev) == device.address {
                found = dev; break
            }
        }
        guard let found else { throw NetMDError.usb("Device disappeared") }
        var h: OpaquePointer?
        let rc = libusb_open(found, &h)
        guard rc == 0, let h else { throw NetMDError.usb("Cannot open device: \(usbError(rc))") }
        handle = h

        // Configuration 1 is the only one NetMD exposes; ignore "already set" failures.
        _ = libusb_set_configuration(h, 1)
        let claim = libusb_claim_interface(h, interfaceNumber)
        guard claim == 0 else {
            libusb_close(h); handle = nil
            throw NetMDError.usb("Cannot claim interface: \(usbError(claim)). Is another app (e.g. a browser tab with Web MiniDisc) using the device?")
        }
        // Drain any stale reply left over from a previous session.
        if let len = try? replyLength(), len > 0 { _ = try? readReply() }
    }

    deinit { close() }

    public func close() {
        guard let h = handle else { return }
        libusb_release_interface(h, interfaceNumber)
        libusb_close(h)
        handle = nil
    }

    // MARK: - Control transfers

    private func controlIn(request: UInt8, length: Int) throws -> [UInt8] {
        guard let h = handle else { throw NetMDError.usb("Device closed") }
        var buf = [UInt8](repeating: 0, count: max(length, 1))
        let type = UInt8(LIBUSB_ENDPOINT_IN.rawValue) | UInt8(LIBUSB_REQUEST_TYPE_VENDOR.rawValue) | UInt8(LIBUSB_RECIPIENT_INTERFACE.rawValue)
        let rc = libusb_control_transfer(h, type, request, 0, 0, &buf, UInt16(length), Self.controlTimeout)
        guard rc >= 0 else { throw NetMDError.usb("control IN failed: \(usbError(rc))") }
        return Array(buf.prefix(Int(rc)))
    }

    private func controlOut(request: UInt8, data: [UInt8]) throws {
        guard let h = handle else { throw NetMDError.usb("Device closed") }
        var d = data
        let type = UInt8(LIBUSB_ENDPOINT_OUT.rawValue) | UInt8(LIBUSB_REQUEST_TYPE_VENDOR.rawValue) | UInt8(LIBUSB_RECIPIENT_INTERFACE.rawValue)
        let rc = libusb_control_transfer(h, type, request, 0, 0, &d, UInt16(d.count), Self.controlTimeout)
        guard rc >= 0 else { throw NetMDError.usb("control OUT failed: \(usbError(rc))") }
    }

    public func replyLength() throws -> Int {
        let r = try controlIn(request: 0x01, length: 4)
        return r.count > 2 ? Int(r[2]) : 0
    }

    public func sendCommand(_ command: [UInt8]) throws {
        try controlOut(request: 0x80, data: command)
    }

    /// Waits for the device to announce a reply, then reads it.
    public func readReply() throws -> [UInt8] {
        try readReply(request: 0x81)
    }

    /// Reads exactly `length` bytes without first polling for an announced reply length. Needed
    /// after `USBCodeExecution`-style commands: the injected code writes its result straight into
    /// the reply buffer without necessarily going through the firmware's normal "set reply
    /// length" step, so polling for an announcement here can hang. Still acks via one
    /// `replyLength()` call afterwards, matching netmd-js's `overrideLength` path.
    public func readReplyFixedLength(_ length: Int) throws -> [UInt8] {
        let data = try controlIn(request: 0x81, length: length)
        _ = try? replyLength()
        return data
    }

    /// The vendor-extension "factory mode" command set (0x18xx AV/C opcodes guarded by an auth
    /// handshake). Same transport, different request codes on both directions.
    public func sendFactoryCommand(_ command: [UInt8]) throws {
        try controlOut(request: 0xff, data: command)
    }

    public func readFactoryReply() throws -> [UInt8] {
        try readReply(request: 0xff)
    }

    private func readReply(request: UInt8) throws -> [UInt8] {
        var len = try replyLength()
        var delay = 0.010
        var waited = 0.0
        while len == 0 {
            if waited > 120 { throw NetMDError.usb("Timed out waiting for a reply from the device") }
            Thread.sleep(forTimeInterval: delay)
            waited += delay
            delay = min(delay * 2, 0.5)
            len = try replyLength()
        }
        let data = try controlIn(request: request, length: len)
        _ = try? replyLength()
        return data
    }

    // MARK: - Bulk transfers

    public func readBulk(length: Int, chunkSize: Int = 0x10000, progress: ((Int, Int) -> Void)? = nil) throws -> [UInt8] {
        guard let h = handle else { throw NetMDError.usb("Device closed") }
        var out = [UInt8](); out.reserveCapacity(length)
        var buf = [UInt8](repeating: 0, count: chunkSize)
        while out.count < length {
            let want = min(length - out.count, chunkSize)
            var got: Int32 = 0
            let rc = libusb_bulk_transfer(h, Self.bulkReadEndpoint, &buf, Int32(want), &got, Self.bulkTimeout)
            guard rc == 0 || (rc == Int32(LIBUSB_ERROR_OVERFLOW.rawValue) && got > 0) else {
                throw NetMDError.usb("bulk read failed: \(usbError(rc))")
            }
            out.append(contentsOf: buf.prefix(Int(got)))
            progress?(length, out.count)
        }
        return out
    }

    public func writeBulk(_ data: [UInt8]) throws {
        guard let h = handle else { throw NetMDError.usb("Device closed") }
        var d = data
        var offset = 0
        while offset < d.count {
            var sent: Int32 = 0
            let n = d.count - offset
            let rc = d.withUnsafeMutableBufferPointer { p in
                libusb_bulk_transfer(h, Self.bulkWriteEndpoint, p.baseAddress! + offset, Int32(n), &sent, Self.bulkTimeout)
            }
            guard rc == 0 else { throw NetMDError.usb("bulk write failed: \(usbError(rc))") }
            offset += Int(sent)
        }
    }
}
