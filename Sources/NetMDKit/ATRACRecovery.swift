import Foundation

/// "Homebrew mode" track recovery: reads a track's raw ATRAC/LP data straight out of the
/// player's DRAM cache via factory mode, for decks (like most non-MZ-RH1 NetMD units) that don't
/// support the standard track-download command. Ported from netmd-exploits'
/// `AtracRecovery.downloadTrackGenerator`, which is itself the only implementation of this that
/// has been tested against real hardware — this port follows its structure closely rather than
/// simplifying it, since the sector bookkeeping (sound-group boundaries, bad-sector detection and
/// realignment-by-seeking) is exactly the part that's easy to get subtly wrong.
public protocol SectorRecoveryBackend {
    /// Reads whichever DRAM sector the backend is currently positioned at; each call advances.
    /// Returns a 2352-byte CD-style sector: 20 bytes of position metadata + 2332 bytes of payload.
    func readNextSector() throws -> [UInt8]
    /// Points the backend at logical sector `sector`, with `sectorsRemaining` sectors left to go
    /// (some backends use this as a transfer-size hint).
    func setSectorToRead(_ sector: Int, remaining: Int) throws
    func startDownload(track: Int) throws
    func finishDownload() throws
}

public struct RecoveryProgress { public var read: Int; public var total: Int; public var action: String }

public struct RecoveryConfig {
    public var removeLPBytes = true
    public var verifyValidAtrac = true
    public var respectSoundGroupBoundaries = true
    public var writeHeader = true
    public var maxBadSectors = 15
    public init() {}
}

public enum ATRACRecovery {
    /// Downloads one track and returns a ready-to-save file (AEA for SP, WAV for LP2/LP4).
    public static func downloadTrack(
        _ track: Int, // 0-indexed, matching the rest of NetMDKit
        toc: UTOC,
        backend: SectorRecoveryBackend,
        iface: NetMDInterface,
        factory: FactoryInterface,
        versionCode: String,
        config: RecoveryConfig = RecoveryConfig(),
        progress: ((RecoveryProgress) -> Void)? = nil,
        isCancelled: @escaping () -> Bool = { false }
    ) throws -> (data: [UInt8], fileExtension: String) {
        let fragments = toc.fragments(forTrack: track + 1)
        guard let root = fragments.first else { throw NetMDError.protocolError("Track \(track) has no TOC fragment") }
        let format = recoveredFormat(for: root)

        var ranges: [(start: Int, end: Int)] = []
        var splices: [Int: (start: Int?, end: Int?)] = [:]
        var allSectors = 0
        for f in fragments {
            let s = f.start.logical, e = f.end.logical
            ranges.append((s, e))
            allSectors += e - s + 1
            splices[s, default: (nil, nil)].start = f.start.group
            splices[e & ~1, default: (nil, nil)].end = f.end.group
        }
        func isPartOfTrack(_ logical: Int) -> Bool { ranges.contains { logical >= $0.start && logical <= $0.end } }

        var out = [UInt8]()
        let fileExtension = format == .lp2 || format == .lp4 ? "wav" : "aea"
        if config.writeHeader {
            if format == .lp2 || format == .lp4 {
                out += AEAWAV.wavHeader(format: format, byteCount: allSectors * (2332 - 20 * 11))
            } else {
                out += AEAWAV.aeaHeader(title: toc.title(forTrack: track + 1) ?? "", channels: format == .spMono ? 1 : 2, soundGroups: allSectors * 11)
            }
        }

        try iface.gotoTrack(track)
        // Explicitly seeking to the start (not just selecting the track) is what actually gets
        // the firmware to begin populating its DRAM cache from the beginning of the track —
        // skipping this was leaving the first sectors read stale/undefined.
        try iface.gotoTime(track, hour: 0, minute: 0, second: 0)
        try waitForDiscToStopSpinning(factory: factory, versionCode: versionCode)
        try backend.startDownload(track: track)
        try backend.setSectorToRead(0, remaining: allSectors + 2)
        defer { try? backend.finishDownload() }

        var sectorsRead = 0, sector = 0
        var sectorPositionsRead = [Int]()
        var nextBeginInclude = 0, nextBeginRemove = 0
        var badSectorStreak = 0
        var isAfterBlacklist = false
        var blacklist = [[UInt8]]()
        var alignmentKnockback = 0.0
        var dumpedFirstBadSector = false
        var dumpPath: String?
        var firstBadSectorPreview: String?

        mainLoop: while sector < 0xfff {
            if isCancelled() { throw NetMDError.cancelled }
            if sectorsRead >= allSectors && nextBeginInclude == 0 { break }

            let raw = try backend.readNextSector()
            sector += 1
            guard raw.count >= 20 else { continue }
            let metadata = Array(raw.prefix(20))
            let posBytes = Array(metadata.suffix(8).prefix(3))
            let currentLogical = (Int(posBytes[0]) << 8 | Int(posBytes[1])) * 32 + Int(posBytes[2])
            var audio = Array(raw.suffix(from: 20))
            var wasEdgeCase = false

            if nextBeginInclude > 0 {
                audio = Array(audio.prefix(nextBeginInclude)); nextBeginInclude = 0; wasEdgeCase = true
            } else if nextBeginRemove > 0 {
                audio = Array(audio.dropFirst(nextBeginRemove)); nextBeginRemove = 0; wasEdgeCase = true
            } else if let splice = splices[currentLogical], config.respectSoundGroupBoundaries {
                var start = Double(splice.start ?? 0)
                let end = splice.end ?? -1
                if start >= 5 { start -= 5.5 }
                let startByte = Int(start * 424), endByte = end == -1 ? audio.count : (end + 1) * 424
                if startByte > audio.count {
                    nextBeginInclude = startByte - audio.count
                    sectorPositionsRead.append(currentLogical); sectorsRead += 1; isAfterBlacklist = false
                    continue
                }
                if endByte > audio.count {
                    nextBeginInclude = endByte - audio.count + startByte
                    audio = Array(audio.dropFirst(startByte))
                } else {
                    audio = Array(audio[startByte..<endByte])
                }
            }

            let failedValidity = config.verifyValidAtrac && !validSector(audio)
            let outOfRange = !isPartOfTrack(currentLogical) && !wasEdgeCase
            let repeated = sectorPositionsRead.contains(currentLogical)
            let invalid = failedValidity || outOfRange || repeated
            if invalid {
                if raw.count == 2352 && blacklist.contains(where: { $0 == metadata }) {
                    if isAfterBlacklist { sectorsRead += 1; isAfterBlacklist = false }
                    continue
                }
                // One-time raw dump of the first bad sector this run, for diagnosing exactly what
                // came back — the alert only has room for a short preview, the file has everything.
                if sectorsRead == 0 && dumpedFirstBadSector == false {
                    dumpedFirstBadSector = true
                    dumpPath = dumpRawSector(raw, track: track, logical: currentLogical)
                    firstBadSectorPreview = hexPreview(raw)
                }
                let reason = outOfRange ? "sector 0x\(String(currentLogical, radix: 16)) is outside this track's range \(ranges.map { "0x\(String($0.start, radix: 16))-0x\(String($0.end, radix: 16))" })"
                    : repeated ? "sector 0x\(String(currentLogical, radix: 16)) was already read"
                    : "sector 0x\(String(currentLogical, radix: 16)) failed ATRAC frame validity"
                var originalSeconds = Double(sectorsRead) * (704.0 / 11025.0) - alignmentKnockback
                if format != .sp {
                    var rep = timeToRepresentation(originalSeconds)
                    switch format {
                    case .spMono, .lp2: translateFromLP2Mono(&rep)
                    case .lp4: translateFromLP4(&rep)
                    default: break
                    }
                    originalSeconds = representationToTime(rep)
                }
                if sector < 100 {
                    badSectorStreak += 1
                    if badSectorStreak > config.maxBadSectors {
                        throw NetMDError.protocolError("""
                            Too many consecutive bad sectors; aborting to protect the disc/laser. \
                            Last: \(reason). Read \(sectorsRead)/\(allSectors) sectors OK before this.\
                            \(dumpPath.map { " Raw sector saved to \($0)." } ?? "")
                            """)
                    }
                }
                blacklist.append(metadata)
                isAfterBlacklist = true

                var attempt = 0, thisKnockback = 0.0
                realign: while true {
                    let seconds = max(0, originalSeconds - thisKnockback)
                    let h = Int(seconds / 3600), m = Int(seconds.truncatingRemainder(dividingBy: 3600) / 60), s = Int(seconds.truncatingRemainder(dividingBy: 60))
                    progress?(RecoveryProgress(read: sectorsRead, total: allSectors, action: "SEEK"))
                    try backend.finishDownload()
                    Thread.sleep(forTimeInterval: 1)
                    try? iface.stop()
                    var tries = 0
                    while true {
                        do { _ = try iface.gotoTime(track, hour: h, minute: m, second: s); break }
                        catch { tries += 1; if tries > 5 { throw NetMDError.protocolError("Cannot seek to realign after a bad sector") }; Thread.sleep(forTimeInterval: 1) }
                    }
                    try? iface.stop()
                    try waitForDiscToStopSpinning(factory: factory, versionCode: versionCode)
                    try backend.startDownload(track: track)
                    try backend.setSectorToRead(0, remaining: 1)
                    let sync = try backend.readNextSector()
                    guard sync.count >= 20 else { throw NetMDError.protocolError("Cannot realign: short sync sector") }
                    let syncPos = Array(sync.prefix(20).suffix(8).prefix(3))
                    let syncLogical = (Int(syncPos[0]) << 8 | Int(syncPos[1])) * 32 + Int(syncPos[2])
                    guard let revIndex = Array(sectorPositionsRead.reversed()).firstIndex(of: syncLogical) else {
                        if attempt < 3 { attempt += 1; thisKnockback += 2; continue realign }
                        let recent = sectorPositionsRead.suffix(8).map { "0x\(String($0, radix: 16))" }.joined(separator: ", ")
                        throw NetMDError.protocolError("""
                            Cannot realign after a bad sector: \(reason). \
                            Read \(sectorsRead)/\(allSectors) sectors OK before this (track logical range(s) \
                            \(ranges.map { "0x\(String($0.start, radix: 16))-0x\(String($0.end, radix: 16))" })). \
                            Seeked to \(h):\(String(format: "%02d", m)):\(String(format: "%02d", s)) (requested \
                            \(originalSeconds)s minus knockback \(thisKnockback)s), re-sync read back logical \
                            position 0x\(String(syncLogical, radix: 16)), which doesn't match any of the last \
                            positions read: [\(recent)].\(dumpPath.map { " Raw sector saved to \($0)." } ?? "")\
                            \(firstBadSectorPreview.map { " First bytes: \($0)" } ?? "")
                            """)
                    }
                    let alignmentPosition = revIndex + 1
                    sector = 0
                    alignmentKnockback += thisKnockback
                    try backend.setSectorToRead(alignmentPosition, remaining: allSectors - sectorsRead + 2)
                    break realign
                }
                continue
            }

            badSectorStreak = 0
            sectorPositionsRead.append(currentLogical)
            if (format == .lp2 || format == .lp4) && config.removeLPBytes {
                // Each 212-byte ATRAC1 frame has 12 SP-compatibility bytes at the start, 8 at the end.
                var trimmed = [UInt8](); trimmed.reserveCapacity(audio.count)
                var i = 0
                while i + 212 <= audio.count { trimmed += audio[(i + 12)..<(i + 212 - 8)]; i += 212 }
                out += trimmed
            } else {
                out += audio
            }
            sectorsRead += 1
            isAfterBlacklist = false
            progress?(RecoveryProgress(read: sectorsRead, total: allSectors, action: "READ"))
        }
        return (out, fileExtension)
    }

    // MARK: Diagnostics

    /// Saves the raw 2352-byte sector (metadata header + payload, exactly as the backend
    /// returned it) to disk for inspection, and returns the path. Best-effort — a failure here
    /// must never mask the real error.
    private static func hexPreview(_ raw: [UInt8], count: Int = 48) -> String {
        raw.prefix(count).map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private static func dumpRawSector(_ raw: [UInt8], track: Int, logical: Int) -> String? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MDKit-debug", isDirectory: true)
        let url = dir.appendingPathComponent("track\(track)-sector0x\(String(logical, radix: 16))-\(Int(Date().timeIntervalSince1970)).bin")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(raw).write(to: url)
            return url.path
        } catch {
            return nil
        }
    }

    // MARK: Sector validity

    private static func validSector(_ data: [UInt8]) -> Bool {
        var frame = data.count / 212 - 1
        while frame >= 0 {
            let base = frame * 212
            guard base + 211 < data.count else { return false }
            if data[base] != data[base + 211] && data[base + 1] != data[base + 210] { return false }
            frame -= 1
        }
        return true
    }

    // MARK: Firmware time-representation conversions (ported verbatim from the firmware's own math)

    private struct TimeRep { var low: Int; var high: Int; var type: Int }

    private static func timeToRepresentation(_ seconds: Double) -> TimeRep {
        let unk = Int(floor(seconds * 1566 / 100))
        return TimeRep(low: unk & 0b11111, high: (unk >> 5) & 0xffff, type: unk & 1 == 0 ? 0 : 6)
    }
    private static func representationToTime(_ t: TimeRep) -> Double {
        let unk = (t.high << 5) | t.low
        return Double(unk * 100 / 1566)
    }
    private static func translateFromLP2Mono(_ t: inout TimeRep) {
        var newHigh = t.high << 1
        var newType = t.type * 2
        while newType > 10 { newType -= 11 }
        var tempLow = ((t.low >> 1) << 1) * 2
        while tempLow > 0x1f { tempLow -= 0x20; newHigh += 1 }
        var newLow = tempLow
        if newType > 5 { newLow |= 1 }
        t.type = newType; t.low = newLow; t.high = newHigh
    }
    private static func translateFromLP4(_ t: inout TimeRep) {
        var newHigh = t.high << 2
        var newType = t.type * 4
        while newType > 10 { newType -= 11 }
        var tempLow = ((t.low >> 1) << 1) * 4
        while tempLow > 0x1f { tempLow -= 0x20; newHigh += 1 }
        var newLow = tempLow
        if newType > 5 { newLow |= 1 }
        t.type = newType; t.low = newLow; t.high = newHigh
    }
}

// MARK: - Disc-spin wait

private let discSpinStateAddress: [String: Int] = [
    "S1.600": 0x02000310, "S1.500": 0x02000310, "S1.400": 0x02000310,
    "S1.300": 0x020002f8, "S1.200": 0x020002ec, "S1.100": 0x020002ec, "S1.000": 0x02000310,
]

/// Mirrors `WaitForDiscToStopSpinning`: polls firmware state on Type-S decks (where the address
/// is known), or just sleeps 20s on everything else, exactly like upstream does.
func waitForDiscToStopSpinning(factory: FactoryInterface, versionCode: String, maxWait: TimeInterval = 20) throws {
    guard versionCode.hasPrefix("S"), let address = discSpinStateAddress[versionCode] else {
        Thread.sleep(forTimeInterval: maxWait)
        return
    }
    let deadline = Date().addingTimeInterval(maxWait)
    try factory.changeMemoryState(address: address, length: 1, type: .mapped, state: .read)
    defer { try? factory.changeMemoryState(address: address, length: 1, type: .mapped, state: .close) }
    while Date() < deadline {
        let state = try factory.rawRead(address: address, length: 1, type: .mapped)
        if let byte = state.first, (byte >> 4) & 1 != 0 { break }
        Thread.sleep(forTimeInterval: 0.5)
    }
}
