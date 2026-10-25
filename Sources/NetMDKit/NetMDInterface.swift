import Foundation

public enum DiscFormat: Int {
    case lp4 = 0, lp2 = 2, spMono = 4, spStereo = 6
}

public enum Wireformat: Int {
    case pcm = 0, l105kbps = 0x90, lp2 = 0x94, lp4 = 0xa8

    public var frameSize: Int {
        switch self {
        case .pcm: return 2048
        case .lp2: return 192
        case .l105kbps: return 152
        case .lp4: return 96
        }
    }
    public var discFormat: DiscFormat {
        switch self {
        case .pcm: return .spStereo
        case .lp2, .l105kbps: return .lp2
        case .lp4: return .lp4
        }
    }
}

public enum Encoding: Int, Sendable {
    case sp = 0x90, lp2 = 0x92, lp4 = 0x93

    public var label: String {
        switch self { case .sp: return "SP"; case .lp2: return "LP2"; case .lp4: return "LP4" }
    }
}

public enum Channels: Int, Sendable { case stereo = 0, mono = 1 }
public enum TrackFlag: Int { case unprotected = 0, protected = 3 }
public struct DiscFlag { public static let writable = 0x10, writeProtected = 0x40 }

public enum NetMDLevel: Int { case level1 = 0x20, level2 = 0x50, level3 = 0x70 }

enum Descriptor: String {
    case discTitleTD = "10 1801"
    case audioUTOC1TD = "10 1802"
    case audioUTOC4TD = "10 1803"
    case audioContentsTD = "10 1001"
    case rootTD = "10 1000"
    case discSubunitIdentifier = "00"
    case operatingStatusBlock = "80 00"
}

enum DescriptorAction: String { case openRead = "01", openWrite = "03", close = "00" }

private enum PlayAction: Int { case play = 0x75, pause = 0x7d, fastForward = 0x39, rewind = 0x49 }
private enum TrackMove: Int { case previous = 0x0002, next = 0x8001, restart = 0x0001 }

private enum ResponseStatus: UInt8 {
    case notImplemented = 0x08, accepted = 0x09, rejected = 0x0a, inTransition = 0x0b, implemented = 0x0c, changed = 0x0d, interim = 0x0f
}

public struct EncryptedPacket {
    public var key: [UInt8]
    public var iv: [UInt8]
    public var data: [UInt8]
}

/// Port of netmd-js `NetMDInterface`: the AV/C-style command set spoken by NetMD recorders.
/// Not thread-safe by itself: the app serialises every call onto one I/O queue, which is what makes
/// handing it across concurrency domains safe.
public final class NetMDInterface: @unchecked Sendable {
    public let transport: NetMDTransport
    public var device: DeviceDefinition { transport.device.definition }

    static let maxInterimReadAttempts = 4
    static let interimRetryInterval = 0.1

    public init(transport: NetMDTransport) { self.transport = transport }

    // MARK: Low-level

    private func changeDescriptorState(_ d: Descriptor, _ a: DescriptorAction) {
        // Errors here are benign (descriptor may already be in the requested state).
        _ = try? sendQuery(Query.format("1808 \(d.rawValue) \(a.rawValue) 00"))
    }

    @discardableResult
    func sendQuery(_ query: [UInt8], test: Bool = false, acceptInterim: Bool = false) throws -> [UInt8] {
        try transport.sendCommand([test ? 0x02 : 0x00] + query)
        return try readReply(acceptInterim: acceptInterim)
    }

    func readReply(acceptInterim: Bool = false) throws -> [UInt8] {
        var attempt = 0
        while attempt < Self.maxInterimReadAttempts {
            let data = try transport.readReply()
            guard let first = data.first else { throw NetMDError.protocolError("Empty reply") }
            switch ResponseStatus(rawValue: first) {
            case .notImplemented: throw NetMDError.notImplemented("status 0x08")
            case .rejected: throw NetMDError.rejected(data.map { String(format: "%02x", $0) }.joined())
            case .interim where !acceptInterim:
                Thread.sleep(forTimeInterval: Self.interimRetryInterval * (pow(2, Double(attempt)) - 1))
                attempt += 1
                continue
            default:
                return Array(data.dropFirst())
            }
        }
        throw NetMDError.rejected("Max attempts reading interim status reached")
    }

    private func q(_ fmt: String, _ args: QArg...) throws -> [UInt8] { try Query.format(fmt, args: args) }

    // MARK: Subunit / session

    public func netMDLevel() throws -> NetMDLevel {
        changeDescriptorState(.discSubunitIdentifier, .openRead)
        defer { changeDescriptorState(.discSubunitIdentifier, .close) }
        let reply = try sendQuery(q("1809 00 ff00 0000 0000"))
        let res = try Query.scan(reply, "1809 00 1000 %?%? %?%? %w %b %b %b %b %w %*")
        let amtLists = res[5].intValue
        let buffer = res[6].bytesValue
        var off = 0
        func multi(_ n: Int) -> Int {
            var out = 0
            for _ in 0..<n { out = (out << 8) | Int(off < buffer.count ? buffer[off] : 0); off += 1 }
            return out
        }
        for _ in 0..<amtLists { _ = multi(res[2].intValue) }
        _ = multi(2); _ = multi(2)
        off += 2 // attributes, version
        let amtTypes = Int(off < buffer.count ? buffer[off] : 0); off += 1
        var level: NetMDLevel?
        for _ in 0..<amtTypes {
            let type = multi(2)
            let profile = Int(off < buffer.count ? buffer[off] : 0); off += 1
            off += 1 // attributes
            _ = multi(2)
            off += 2 // audio version, MDClip
            if type == 0x301 { level = NetMDLevel(rawValue: profile) }
        }
        guard let level else { throw NetMDError.unsupported("This recorder doesn't support MiniDiscs") }
        return level
    }

    public func acquire() throws {
        let r = try sendQuery(q("ff 010c ffff ffff ffff ffff ffff ffff"))
        try Query.scan(r, "ff 010c ffff ffff ffff ffff ffff ffff")
    }

    public func release() throws {
        let r = try sendQuery(q("ff 0100 ffff ffff ffff ffff ffff ffff"))
        try Query.scan(r, "ff 0100 ffff ffff ffff ffff ffff ffff")
    }

    // MARK: Status / transport controls

    public func getStatus() throws -> [UInt8] {
        changeDescriptorState(.operatingStatusBlock, .openRead)
        defer { changeDescriptorState(.operatingStatusBlock, .close) }
        let r = try sendQuery(q("1809 8001 0230 8800 0030 8804 00 ff00 00000000"))
        return try Query.scan(r, "1809 8001 0230 8800 0030 8804 00 1000 00090000 %x")[0].bytesValue
    }

    public func isDiscPresent() throws -> Bool { try getStatus()[4] == 0x40 }

    public func getPlaybackStatus2() throws -> [UInt8] {
        changeDescriptorState(.operatingStatusBlock, .openRead)
        defer { changeDescriptorState(.operatingStatusBlock, .close) }
        let r = try sendQuery(q("1809 8001 0330 %w 0030 8805 0030 %w 00 ff00 00000000", .b(0x8802), .b(0x8806)))
        return try Query.scan(r, "1809 8001 0330 %?%? %?%? %?%? %?%? %?%? %? 1000 00%?0000 %x %?")[0].bytesValue
    }

    /// Returns [track, hour, minute, second, frame] or nil if no position is available.
    public func getPosition() throws -> [Int]? {
        changeDescriptorState(.operatingStatusBlock, .openRead)
        defer { changeDescriptorState(.operatingStatusBlock, .close) }
        let reply: [UInt8]
        do {
            reply = try sendQuery(q("1809 8001 0430 8802 0030 8805 0030 0003 0030 0002 00 ff00 00000000"))
        } catch NetMDError.rejected { return nil }
        let res = try Query.scan(reply, "1809 8001 0430 %?%? %?%? %?%? %?%? %?%? %?%? %?%? %? %?00 00%?0000 000b 0002 0007 00 %w %B %B %B %B")
        return res.map { $0.intValue }
    }

    public func ejectDisc() throws { try sendQuery(q("18c1 ff 6000")) }

    public func canEjectDisc() -> Bool {
        (try? sendQuery(q("18c1 ff 6000"), test: true)) != nil
    }

    private func play(_ a: PlayAction) throws {
        let r = try sendQuery(q("18c3 ff %b 000000", .b(a.rawValue)))
        try Query.scan(r, "18c3 00 %b 000000")
    }
    public func play() throws { try play(.play) }
    public func pause() throws { try play(.pause) }
    public func fastForward() throws { try play(.fastForward) }
    public func rewind() throws { try play(.rewind) }

    public func stop() throws {
        // Some devices (LAM-1) reject this; harmless.
        if let r = try? sendQuery(q("18c5 ff 00000000")) { _ = try? Query.scan(r, "18c5 00 00000000") }
    }

    @discardableResult
    public func gotoTrack(_ track: Int) throws -> Int {
        let r = try sendQuery(q("1850 ff010000 0000 %w", .b(track)))
        return try Query.scan(r, "1850 00010000 0000 %w")[0].intValue
    }

    /// Seeks to `hour:minute:second:frame` (frames are 1/512 sec) within `track`. Returns the
    /// device's own echo of the position as `[track, hour, minute, second, frame]`.
    @discardableResult
    public func gotoTime(_ track: Int, hour: Int = 0, minute: Int = 0, second: Int = 0, frame: Int = 0) throws -> [Int] {
        let r = try sendQuery(q("1850 ff000000 0000 %w %B%B%B%B", .b(track), .b(hour), .b(minute), .b(second), .b(frame)))
        return try Query.scan(r, "1850 00000000 %?%? %w %B%B%B%B").map { $0.intValue }
    }

    private func trackChange(_ m: TrackMove) throws {
        let r = try sendQuery(q("1850 ff10 00000000 %w", .b(m.rawValue)))
        try Query.scan(r, "1850 0010 00000000 %?%?")
    }
    public func nextTrack() throws { try trackChange(.next) }
    public func previousTrack() throws { try trackChange(.previous) }
    public func restartTrack() throws { try trackChange(.restart) }

    // MARK: Disc & track info

    public func eraseDisc() throws {
        let r = try sendQuery(q("1840 ff 0000"))
        try Query.scan(r, "1840 00 0000")
    }

    public func getDiscFlags() throws -> Int {
        changeDescriptorState(.rootTD, .openRead)
        defer { changeDescriptorState(.rootTD, .close) }
        let r = try sendQuery(q("1806 01101000 ff00 0001000b"))
        return try Query.scan(r, "1806 01101000 1000 0001000b %b")[0].intValue
    }

    public func getTrackCount() throws -> Int {
        changeDescriptorState(.audioContentsTD, .openRead)
        defer { changeDescriptorState(.audioContentsTD, .close) }
        let r = try sendQuery(q("1806 02101001 3000 1000 ff00 00000000"))
        return try Query.scan(r, "1806 02101001 %?%? %?%? 1000 00%?0000 0006 0010000200%b")[0].intValue
    }

    /// Raw disc title including group markup (`0;Title//1-3;Group//`).
    public func rawDiscTitle(wide: Bool = false) throws -> String {
        changeDescriptorState(.audioContentsTD, .openRead)
        changeDescriptorState(.discTitleTD, .openRead)
        defer {
            changeDescriptorState(.discTitleTD, .close)
            changeDescriptorState(.audioContentsTD, .close)
        }
        var done = 0, remaining = 0, total = 1
        var chunks = [String]()
        while done < total {
            let r = try sendQuery(q("1806 02201801 00%b 3000 0a00 ff00 %w%w", .b(wide ? 1 : 0), .b(remaining), .b(done)))
            var chunkSize: Int
            let text: String
            if remaining == 0 {
                let res = try Query.scan(r, "1806 02201801 00%? 3000 0a00 1000 %w0000 %?%?000a %w %*")
                chunkSize = res[0].intValue - 6
                total = res[1].intValue
                text = Titles.decodeSJIS(res[2].bytesValue)
            } else {
                let res = try Query.scan(r, "1806 02201801 00%? 3000 0a00 1000 %w%?%? %*")
                chunkSize = res[0].intValue
                text = Titles.decodeSJIS(res[1].bytesValue)
            }
            if chunkSize <= 0 { break }
            chunks.append(text)
            done += chunkSize
            remaining = total - done
        }
        return chunks.joined()
    }

    public func discTitle(wide: Bool = false) throws -> String {
        var title = try rawDiscTitle(wide: wide)
        let delim = wide ? "／／" : "//"
        let marker = wide ? "０；" : "0;"
        if title.hasSuffix(delim) {
            let first = title.components(separatedBy: delim)[0]
            title = first.hasPrefix(marker) ? String(first.dropFirst(2)) : ""
        }
        return title
    }

    public struct RawGroup { public var name: String?; public var fullWidthName: String?; public var tracks: [Int] }

    public func trackGroupList() throws -> [RawGroup] {
        let rawTitle = try rawDiscTitle()
        let groupList = rawTitle.components(separatedBy: "//")
        let trackCount = try getTrackCount()
        let rawFull = try rawDiscTitle(wide: true)
        let fullGroups = rawFull.components(separatedBy: "／／")
        var seen = Set<Int>()
        var result = [RawGroup]()

        for group in groupList {
            if group.isEmpty { continue }
            if group.hasPrefix("0;") || !group.contains(";") || !rawTitle.contains("//") { continue }
            guard let semi = group.firstIndex(of: ";") else { continue }
            let range = String(group[..<semi])
            if range.isEmpty { continue }
            let name = String(group[group.index(after: semi)...])
            let fullRange = Titles.halfWidthToFullWidthRange(range)
            let fullName = fullGroups.first(where: { $0.hasPrefix(fullRange) }).map { String($0.dropFirst(fullRange.count + 1)) }

            let parts = range.split(separator: "-").map { Int($0) }
            guard let lo = parts.first.flatMap({ $0 }) else { continue }
            var hi = (parts.count > 1 ? parts[1] : lo) ?? lo
            hi = min(hi, trackCount)
            guard lo >= 0, lo <= hi else { continue }
            var tracks = [Int]()
            for t in (lo - 1)..<hi {
                if seen.contains(t) { throw NetMDError.protocolError("Track \(t) is in 2 groups") }
                seen.insert(t); tracks.append(t)
            }
            result.append(RawGroup(name: name, fullWidthName: fullName, tracks: tracks))
        }
        let ungrouped = (0..<trackCount).filter { !seen.contains($0) }
        if !ungrouped.isEmpty { result.insert(RawGroup(name: nil, fullWidthName: nil, tracks: ungrouped), at: 0) }
        return result
    }

    public func trackTitle(_ track: Int, wide: Bool = false) throws -> String {
        let desc: Descriptor = wide ? .audioUTOC4TD : .audioUTOC1TD
        changeDescriptorState(desc, .openRead)
        defer { changeDescriptorState(desc, .close) }
        let r = try sendQuery(q("1806 022018%b %w 3000 0a00 ff00 00000000", .b(wide ? 3 : 2), .b(track)))
        let res = try Query.scan(r, "1806 022018%? %?%? %?%? %?%? 1000 00%?0000 00%?000a %x")
        return Titles.decodeSJIS(res[0].bytesValue)
    }

    public func setDiscTitle(_ rawTitle: String, wide: Bool = false) throws {
        let current = try rawDiscTitle(wide: wide)
        if current == rawTitle { return } // Writing the same title upsets some devices (LAM).
        let oldLen = Titles.sjisLength(current)
        let title = wide ? Titles.sanitizeFullWidth(rawTitle) : sanitizeGroupedHalfWidth(rawTitle)
        let newLen = Titles.sjisLength(title)
        let sharp = transport.device.definition.vendorId == 0x04dd
        if sharp {
            changeDescriptorState(.audioUTOC1TD, .openWrite)
        } else {
            changeDescriptorState(.discTitleTD, .close)
            changeDescriptorState(.discTitleTD, .openWrite)
        }
        let r = try sendQuery(q("1807 02201801 00%b 3000 0a00 5000 %w 0000 %w %*",
                                .b(wide ? 1 : 0), .b(newLen), .b(oldLen), .bytes(Titles.encodeSJIS(title))))
        try Query.scan(r, "1807 02201801 00%? 3000 0a00 5000 %?%? 0000 %?%?")
        if sharp {
            changeDescriptorState(.audioUTOC1TD, .close)
        } else {
            changeDescriptorState(.discTitleTD, .close)
            changeDescriptorState(.discTitleTD, .openRead)
            changeDescriptorState(.discTitleTD, .close)
        }
    }

    /// Group markup contains `//` and `;`, which must survive sanitization untouched.
    private func sanitizeGroupedHalfWidth(_ s: String) -> String { Titles.sanitizeHalfWidth(s) }

    public func setTrackTitle(_ track: Int, title raw: String, wide: Bool = false) throws {
        let title = wide ? Titles.sanitizeFullWidth(raw) : Titles.sanitizeHalfWidth(raw)
        let newLen = Titles.sjisLength(title)
        var oldLen = 0
        do {
            let current = try trackTitle(track, wide: wide)
            if current == title { return }
            oldLen = Titles.sjisLength(current)
        } catch NetMDError.rejected { oldLen = 0 }

        let desc: Descriptor = wide ? .audioUTOC4TD : .audioUTOC1TD
        changeDescriptorState(desc, .openWrite)
        defer { changeDescriptorState(desc, .close) }
        let r = try sendQuery(q("1807 022018%b %w 3000 0a00 5000 %w 0000 %w %*",
                                .b(wide ? 3 : 2), .b(track), .b(newLen), .b(oldLen), .bytes(Titles.encodeSJIS(title))))
        try Query.scan(r, "1807 022018%? %?%? 3000 0a00 5000 %?%? 0000 %?%?")
    }

    public func eraseTrack(_ track: Int) throws { try sendQuery(q("1840 ff01 00 201001 %w", .b(track))) }
    public func moveTrack(from: Int, to: Int) throws { try sendQuery(q("1843 ff00 00 201001 %w 201001 %w", .b(from), .b(to))) }

    private func trackInfo(_ track: Int, _ p1: Int, _ p2: Int) throws -> [UInt8] {
        changeDescriptorState(.audioContentsTD, .openRead)
        defer { changeDescriptorState(.audioContentsTD, .close) }
        let r = try sendQuery(q("1806 02201001 %w %w %w ff00 00000000", .b(track), .b(p1), .b(p2)))
        return try Query.scan(r, "1806 02201001 %?%? %?%? %?%? 1000 00%?0000 %x")[0].bytesValue
    }

    /// [hours, minutes, seconds, frames]
    public func trackLength(_ track: Int) throws -> [Int] {
        let raw = try trackInfo(track, 0x3000, 0x0100)
        return try Query.scan(raw, "0001 0006 0000 %B %B %B %B").map { $0.intValue }
    }

    /// [codec, channels]
    public func trackEncoding(_ track: Int) throws -> [Int] {
        let raw = try trackInfo(track, 0x3080, 0x0700)
        return try Query.scan(raw, "8007 0004 0110 %b %b").map { $0.intValue }
    }

    public func trackFlags(_ track: Int) throws -> Int {
        changeDescriptorState(.audioContentsTD, .openRead)
        defer { changeDescriptorState(.audioContentsTD, .close) }
        let r = try sendQuery(q("1806 01201001 %w ff00 00010008", .b(track)))
        return try Query.scan(r, "1806 01201001 %?%? 10 00 00010008 %b")[0].intValue
    }

    /// Three [hours, minutes, seconds, frames] tuples: used, total, left.
    public func discCapacity() throws -> [[Int]] {
        changeDescriptorState(.rootTD, .openRead)
        defer { changeDescriptorState(.rootTD, .close) }
        let r = try sendQuery(q("1806 02101000 3080 0300 ff00 00000000"))
        var res = try Query.scan(r, "1806 02101000 3080 0300 1000 001d0000 001b %?03 0017 8000 0005 %W %B %B %B 0005 %W %B %B %B 0005 %W %B %B %B").map { $0.intValue }
        var out = [[Int]]()
        for _ in 0..<3 { out.append(Array(res.prefix(4))); res.removeFirst(4) }
        return out
    }

    // MARK: Track download from player (MZ-RH1 / M200 only)

    public func saveTrack(_ track: Int, progress: ((Int, Int) -> Void)?) throws -> (DiscFormat, Int, [UInt8]) {
        let r = try sendQuery(q("1800 080046 f003010330 ff00 1001 %w", .b(track + 1)), acceptInterim: true)
        let res = try Query.scan(r, "1800 080046 f0030103 300000 1001 %w %b %d")
        let data = try transport.readBulk(length: res[2].intValue, progress: progress)
        try Query.scan(try readReply(), "1800 080046 f003010330 0000 1001 %?%? %?%?")
        Thread.sleep(forTimeInterval: 0.5)
        let format = DiscFormat(rawValue: res[1].intValue & 0x06) ?? .spStereo
        return (format, res[0].intValue, data)
    }

    // MARK: Secure session (uploading to the device)

    public func disableNewTrackProtection(_ value: Int) throws {
        let r = try sendQuery(q("1800 080046 f0030103 2b ff %w", .b(value)))
        try Query.scan(r, "1800 080046 f0030103 2b 00 %?%?")
    }

    public func enterSecureSession() throws {
        try Query.scan(try sendQuery(q("1800 080046 f0030103 80 ff")), "1800 080046 f0030103 80 00")
    }

    public func leaveSecureSession() throws {
        try Query.scan(try sendQuery(q("1800 080046 f0030103 81 ff")), "1800 080046 f0030103 81 00")
    }

    public func leafID() throws -> [UInt8] {
        let r = try sendQuery(q("1800 080046 f0030103 11 ff"))
        return try Query.scan(r, "1800 080046 f0030103 11 00 %*")[0].bytesValue
    }

    func sendKeyData(ekbID: UInt32, chain: [[UInt8]], depth: Int, signature: [UInt8]) throws {
        let databytes = 16 + 16 * chain.count + 24
        let r = try sendQuery(q("1800 080046 f0030103 12 ff %w 0000 %w %d %d %d 00000000 %* %*",
                                .b(databytes), .b(databytes), .b(chain.count), .b(depth), .int(UInt64(ekbID)),
                                .bytes(chain.flatMap { $0 }), .bytes(signature)))
        try Query.scan(r, "1800 080046 f0030103 12 01 %?%? %?%?%?%?")
    }

    func sessionKeyExchange(hostNonce: [UInt8]) throws -> [UInt8] {
        let r = try sendQuery(q("1800 080046 f0030103 20 ff 000000 %*", .bytes(hostNonce)))
        return try Query.scan(r, "1800 080046 f0030103 20 %? 000000 %#")[0].bytesValue
    }

    func sessionKeyForget() throws {
        try Query.scan(try sendQuery(q("1800 080046 f0030103 21 ff 000000")), "1800 080046 f0030103 21 00 000000")
    }

    func setupDownload(contentID: [UInt8], kek: [UInt8], sessionKey: [UInt8]) throws {
        let message: [UInt8] = [1, 1, 1, 1] + contentID + kek
        let enc = DES.encrypt(message, key: sessionKey, mode: .cbc)
        let r = try sendQuery(q("1800 080046 f0030103 22 ff 0000 %*", .bytes(enc)))
        try Query.scan(r, "1800 080046 f0030103 22 00 0000")
    }

    func commitTrack(_ track: Int, sessionKey: [UInt8]) throws {
        let auth = DES.encrypt([UInt8](repeating: 0, count: 8), key: sessionKey, mode: .ecb)
        let r = try sendQuery(q("1800 080046 f0030103 48 ff 00 1001 %w %*", .b(track), .bytes(auth)))
        try Query.scan(r, "1800 080046 f0030103 48 00 00 1001 %?%?")
    }

    /// Streams an encrypted track to the device. Returns (track number, UUID, content ID).
    func sendTrack(wireformat: Wireformat, discFormat: DiscFormat, frames: Int, packetSize: Int,
                   packets: () throws -> EncryptedPacket?, sessionKey: [UInt8],
                   progress: ((Int, Int) -> Void)?) throws -> (Int, String, String) {
        Thread.sleep(forTimeInterval: 0.2) // Sharp devices are slow to settle.
        let totalBytes = packetSize + 24
        let r0 = try sendQuery(q("1800 080046 f0030103 28 ff 000100 1001 ffff 00 %b %b %d %d",
                                 .b(wireformat.rawValue), .b(discFormat.rawValue), .b(frames), .b(totalBytes)), acceptInterim: true)
        try Query.scan(r0, "1800 080046 f0030103 28 00 000100 1001 %?%? 00 %*")
        Thread.sleep(forTimeInterval: 0.2)

        var first = true
        var written = 0
        while let p = try packets() {
            progress?(written, totalBytes)
            if first {
                var header: [UInt8] = [0, 0, 0, 0]
                header += withUnsafeBytes(of: UInt32(packetSize).bigEndian, Array.init)
                try transport.writeBulk(header + p.key + p.iv + p.data)
                first = false
            } else {
                try transport.writeBulk(p.data)
            }
            written += p.data.count
        }
        progress?(totalBytes, totalBytes)

        let reply = try readReply()
        _ = try? transport.replyLength()
        let res = try Query.scan(reply, "1800 080046 f0030103 28 00 000100 1001 %w 00 %?%? %?%?%?%? %?%?%?%? %*")
        var enc = res[1].bytesValue
        enc = Array(enc.prefix(enc.count - enc.count % 8))
        let dec = DES.decrypt(enc, key: sessionKey, mode: .cbc)
        func str(_ r: Range<Int>) -> String {
            guard dec.count >= r.upperBound else { return "" }
            return String(decoding: dec[r], as: UTF8.self)
        }
        return (res[0].intValue, str(0..<8), str(12..<32))
    }

    public func trackUUID(_ track: Int) throws -> String {
        let r = try sendQuery(q("1800 080046 f0030103 23 ff 1001 %w", .b(track)))
        return String(decoding: try Query.scan(r, "1800 080046 f0030103 23 00 1001 %?%? %*")[0].bytesValue, as: UTF8.self)
    }
}
