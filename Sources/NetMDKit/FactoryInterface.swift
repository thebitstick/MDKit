import Foundation

/// The vendor "factory mode" command set spoken by Sony/Aiwa NetMD units: raw peripheral memory
/// read/write, the sector-level UTOC peripheral, and the small patch table every factory-mode
/// deck exposes at a fixed RAM address. This is the same command set SonicStage's factory tools
/// and the open-source `netmd-exploits` project use — ported here 1:1 from netmd-js's
/// `NetMDFactoryInterface`. It requires no exploit or vulnerability: it's a documented,
/// Sony-shipped debug interface that happens to be left enabled on consumer decks.
public enum MemoryType: Int { case mapped = 0, eeprom2 = 2, eeprom3 = 3 }
enum MemoryOpenType: Int { case close = 0, read = 1, write = 2, readWrite = 3 }
public enum DisplayMode: Int { case standard = 0, override = 1 }

public enum PatchPeripheralBase: Int { case netmd = 0x03802000, himd = 0x03804000 }

public struct DeviceCode: Sendable {
    public var chipType: Int
    public var hwid: Int
    public var subversion: Int
    public var version: Int
}

/// CRC16-CCITT-ish checksum used by the factory-mode write command. Ported carefully from
/// netmd-js's `calculateChecksum`: note `temp` is its own running value seeded from the element
/// count, not derived from `crc` — only its low 16 bits get replaced each round, so its high bits
/// (0, for any realistic data size) persist across the whole computation independently of `crc`,
/// which is never masked until the very end.
func checksum(_ data: [UInt8], as16Bit: Bool, seed: UInt32 = 0) -> UInt32 {
    var crc = seed
    let elements: [UInt32] = as16Bit
        ? (0..<data.count / 2).map { UInt32(data[2 * $0 + 1]) << 8 | UInt32(data[2 * $0]) }
        : data.map(UInt32.init)
    var temp = UInt32(elements.count)
    for e in elements {
        temp = (temp & 0xffff0000) | (e & 0xffff)
        crc ^= temp
        for _ in 0..<16 {
            let ts = crc & 0x8000
            crc <<= 1
            if ts != 0 { crc ^= 0x1021 }
        }
    }
    return crc & 0xffff
}

public final class FactoryInterface {
    let iface: NetMDInterface
    public init(_ iface: NetMDInterface) { self.iface = iface }

    static let maxInterimReadAttempts = 4
    static let interimRetryInterval = 0.1

    @discardableResult
    func sendQuery(_ query: [UInt8], acceptInterim: Bool = false) throws -> [UInt8] {
        try iface.transport.sendFactoryCommand([0x00] + query)
        return try readReply(acceptInterim: acceptInterim)
    }

    private func readReply(acceptInterim: Bool) throws -> [UInt8] {
        var attempt = 0
        while attempt < Self.maxInterimReadAttempts {
            let data = try iface.transport.readFactoryReply()
            guard let first = data.first else { throw NetMDError.protocolError("Empty factory reply") }
            switch first {
            case 0x08: throw NetMDError.notImplemented("factory status 0x08")
            case 0x0a: throw NetMDError.rejected(data.map { String(format: "%02x", $0) }.joined())
            case 0x0f where !acceptInterim:
                Thread.sleep(forTimeInterval: Self.interimRetryInterval * (pow(2, Double(attempt)) - 1))
                attempt += 1
                continue
            default:
                return Array(data.dropFirst())
            }
        }
        throw NetMDError.rejected("Max attempts reading interim factory status reached")
    }

    private func q(_ fmt: String, _ args: QArg...) throws -> [UInt8] { try Query.format(fmt, args: args) }

    // MARK: Session

    public func auth() throws {
        // "Net MD Walkman" in hex — the documented factory-mode handshake string.
        try sendQuery(q("1801 ff0e 4e6574204d442057616c6b6d616e"))
    }

    public func getDeviceVersion() throws -> Int {
        let r = try sendQuery(q("1813 ff"))
        return try Query.scan(r, "1813 00 00 %B")[0].intValue
    }

    public func getDeviceCode() throws -> DeviceCode {
        let r = try sendQuery(q("1812 ff"))
        let res = try Query.scan(r, "1812 00 %b %b %b %B")
        return DeviceCode(chipType: res[0].intValue, hwid: res[1].intValue, subversion: res[2].intValue, version: res[3].intValue)
    }

    /// Short descriptive firmware id (e.g. "S1.600", "R1.200", "Hx1.0A0") as used throughout the
    /// netmd-exploits compatibility tables.
    public func descriptiveVersion() throws -> String {
        let d = try getDeviceCode()
        let letter: String
        switch d.chipType {
        case 0x20: letter = "R"
        case 0x21: letter = "S"
        case 0x22: letter = "Hn"
        case 0x23: letter = "Hp"
        case 0x24: letter = "Hr"
        case 0x25: letter = "Hx"
        default: letter = "\(d.chipType)?"
        }
        let digits = String(d.version)
        let maj = digits.first.map(String.init) ?? "?"
        let min = digits.count > 1 ? String(digits[digits.index(digits.startIndex, offsetBy: 1)]) : "0"
        return letter + maj + "." + min + String(format: "%02X", d.subversion)
    }

    // MARK: Raw memory

    func changeMemoryState(address: Int, length: Int, type: MemoryType, state: MemoryOpenType, encrypted: Bool = false) throws {
        try sendQuery(q("1820 ff %b %<d %b %b %b", .b(type.rawValue), .b(address), .b(length), .b(state.rawValue), .b(encrypted ? 1 : 0)))
    }

    func rawRead(address: Int, length: Int, type: MemoryType) throws -> [UInt8] {
        let r = try sendQuery(q("1821 ff %b %<d %b", .b(type.rawValue), .b(address), .b(length)))
        var bytes = try Query.scan(r, "1821 00 %? %?%?%?%? %? %?%? %*")[0].bytesValue
        bytes.removeLast(min(2, bytes.count)) // Trailing checksum from the device; verified implicitly by protocol.
        return bytes
    }

    func rawWrite(address: Int, data: [UInt8], type: MemoryType) throws {
        let crc = checksum(data, as16Bit: false)
        try sendQuery(q("1822 ff %b %<d %b 0000 %* %<w", .b(type.rawValue), .b(address), .b(data.count), .bytes(data), .b(Int(crc))))
    }

    /// Open → read/write → close a memory window, as every factory-mode access requires.
    public func read(address: Int, length: Int, type: MemoryType = .mapped) throws -> [UInt8] {
        try changeMemoryState(address: address, length: length, type: type, state: .read)
        defer { try? changeMemoryState(address: address, length: length, type: type, state: .close) }
        return try rawRead(address: address, length: length, type: type)
    }

    public func write(address: Int, data: [UInt8], type: MemoryType = .mapped) throws {
        try changeMemoryState(address: address, length: data.count, type: type, state: .write)
        defer { try? changeMemoryState(address: address, length: data.count, type: type, state: .close) }
        try rawWrite(address: address, data: data, type: type)
    }

    /// `write` can only send small chunks at a time; splits anything bigger into 16-byte pieces.
    public func writeLong(address: Int, data: [UInt8], type: MemoryType = .mapped) throws {
        var offset = 0
        while offset < data.count {
            let chunk = Array(data[offset..<min(offset + 0x10, data.count)])
            try write(address: address + offset, data: chunk, type: type)
            offset += chunk.count
        }
    }

    // MARK: UTOC sector peripheral (0x18 24 / 0x18 25)

    func readMetadataPeripheral(sector: Int, offset: Int, length: Int) throws -> [UInt8] {
        let r = try sendQuery(q("1824 ff %<w %<w %b", .b(sector), .b(offset), .b(length)))
        return try Query.scan(r, "1824 00 %?%?%?%? %b %*")[1].bytesValue
    }

    func writeMetadataPeripheral(sector: Int, offset: Int, data: [UInt8]) throws {
        try sendQuery(q("1825 ff %<w %<w %z", .b(sector), .b(offset), .bytes(data)))
    }

    /// A UTOC sector is 2352 bytes, read/written in 16-byte pieces.
    public func readUTOCSector(_ sector: Int) throws -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(2352)
        for i in 0..<147 { out += try readMetadataPeripheral(sector: sector, offset: i * 0x10, length: 0x10) }
        return out
    }

    public func writeUTOCSector(_ sector: Int, data: [UInt8]) throws {
        guard data.count == 2352 else { throw NetMDError.protocolError("UTOC sector must be 2352 bytes") }
        var offset = 0
        while offset < data.count {
            try writeMetadataPeripheral(sector: sector, offset: offset, data: Array(data[offset..<offset + 0x10]))
            offset += 0x10
        }
    }

    // MARK: Display (factory-mode text override, used by some exploits as a status indicator)

    public func setDisplayMode(_ mode: DisplayMode) throws { try sendQuery(q("1851 ff %b", .b(mode.rawValue))) }

    public func setDisplayOverride(_ text: String, blink: Bool = false) throws {
        var bytes = Titles.encodeSJIS(String(text.prefix(8)))
        bytes += [UInt8](repeating: 0, count: max(0, 10 - bytes.count))
        try sendQuery(q("1852 ff %b %b 00 %*", .b(0), .b(blink ? 1 : 0), .bytes(bytes)))
    }

    // MARK: Patch table (fixed RAM structure every factory-mode deck exposes)

    /// Writes one 4-byte RAM patch into slot `slot` of `max`, the same bit-twiddling sequence
    /// Sir68k's original patcher uses (ported byte-for-byte from `netmd-js`'s `patch()`).
    public func patch(address: Int, value: [UInt8], slot: Int, maxSlots: Int, base: PatchPeripheralBase = .netmd) throws {
        guard value.count == 4 else { throw NetMDError.protocolError("Patch value must be 4 bytes") }
        let b = base.rawValue, slotBase = b + slot * 0x10, control = b + maxSlots * 0x10
        try write(address: control, data: [5])
        try write(address: control, data: [12])
        var pc = try read(address: slotBase, length: 4)
        pc[0] &= 0xfe
        try write(address: slotBase, data: pc)
        pc = try read(address: slotBase, length: 4)
        pc[0] &= 0xfd
        try write(address: slotBase, data: pc)
        try write(address: slotBase + 4, data: leWord(address))
        try write(address: slotBase + 8, data: value)
        pc = try read(address: slotBase, length: 4)
        pc[0] |= 1
        try write(address: slotBase, data: pc)
        try write(address: control, data: [5])
        try write(address: control, data: [9])
    }

    public func unpatch(slot: Int, maxSlots: Int, base: PatchPeripheralBase = .netmd) throws {
        let b = base.rawValue, slotBase = b + slot * 0x10, control = b + maxSlots * 0x10
        try write(address: control, data: [5])
        try write(address: control, data: [12])
        var pc = try read(address: slotBase, length: 4)
        pc[0] &= 0xfe
        try write(address: slotBase, data: pc)
        try write(address: control, data: [5])
        try write(address: control, data: [9])
    }

    public func readPatch(slot: Int, base: PatchPeripheralBase = .netmd) throws -> (address: Int, value: [UInt8]) {
        let slotBase = base.rawValue + slot * 0x10
        let addr = try read(address: slotBase + 4, length: 4)
        let value = try read(address: slotBase + 8, length: 4)
        return (leInt(addr), value)
    }
}

func leWord(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)] }
func leInt(_ b: [UInt8]) -> Int {
    guard b.count >= 4 else { return 0 }
    return Int(b[0]) | Int(b[1]) << 8 | Int(b[2]) << 16 | Int(b[3]) << 24
}
