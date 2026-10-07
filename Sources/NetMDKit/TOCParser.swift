import Foundation

/// Minimal parser for the raw UTOC sector 0 (track → fragment table) and sector 1 (titles),
/// ported from `netmd-tocmanip`. Needed to know exactly which physical sectors make up a track
/// (tracks can be split into several fragments after fragmentation from editing) and what
/// format it was recorded in — information the standard NetMD command set doesn't expose, but
/// which "homebrew mode ripping" needs to reconstruct a track from raw disc sectors.
public struct DiscAddress: Sendable {
    public var cluster: Int, sector: Int, group: Int
    public init(bytes: [UInt8]) {
        cluster = (Int(bytes[0]) << 6) | (Int(bytes[1]) >> 2)
        sector = ((Int(bytes[1]) & 0b11) << 4) | (Int(bytes[2]) >> 4)
        group = Int(bytes[2]) & 0b1111
    }
    /// Logical sector number on the disc.
    public var logical: Int { sector + cluster * 32 }
}

public struct ModeFlag {
    public static let emphasis = 0x1, stereo = 0x2, spMode = 0x4, codecReserved = 0x8
    public static let audio = 0x10, scmsDigCopy = 0x20, scmsUnrestricted = 0x40, writable = 0x80
}

public struct TOCFragment: Sendable {
    public var start: DiscAddress, mode: Int, end: DiscAddress, link: Int
}

struct TitleCell { var title: [UInt8]; var link: Int }

public struct UTOC {
    public var trackMap: [Int] = []          // index: track# (1-based); value: fragment index
    public var trackFragmentList: [TOCFragment] = []
    var titleMap: [Int] = []
    var titleCellList: [TitleCell] = []

    public static func parse(sector0: [UInt8], sector1: [UInt8]? = nil) throws -> UTOC {
        guard sector0.count >= 2352 else { throw NetMDError.protocolError("UTOC sector 0 too short") }
        var toc = UTOC()
        var off = 0x1c // sec0padding
        off += 2 /* deviceSignature */ + 1 /* discNonEmpty */ + 1 /* nTracks */
        off += 0x0f /* sec0apadding */ + 1 /* nextFreeTrackSlot */
        toc.trackMap = sector0[off..<off + 256].map(Int.init); off += 256
        for _ in 0..<256 {
            let start = DiscAddress(bytes: Array(sector0[off..<off + 3])); off += 3
            let mode = Int(sector0[off]); off += 1
            let end = DiscAddress(bytes: Array(sector0[off..<off + 3])); off += 3
            let link = Int(sector0[off]); off += 1
            toc.trackFragmentList.append(TOCFragment(start: start, mode: mode, end: end, link: link))
        }
        if let sector1, sector1.count >= 2352 {
            var o1 = 0x2f + 1 // sec1padding + nextFreeTitleSlot
            toc.titleMap = sector1[o1..<o1 + 256].map(Int.init); o1 += 256
            for _ in 0..<256 {
                let title = Array(sector1[o1..<o1 + 7]); o1 += 7
                let link = Int(sector1[o1]); o1 += 1
                toc.titleCellList.append(TitleCell(title: title, link: link))
            }
        }
        return toc
    }

    /// All fragments belonging to track `track` (1-based, as stored in the TOC), in disc order.
    public func fragments(forTrack track: Int) -> [TOCFragment] {
        guard track >= 1, track < trackMap.count else { return [] }
        var out = [TOCFragment]()
        var idx = trackMap[track]
        var guardCount = 0
        while idx != 0 || out.isEmpty {
            guard idx >= 0, idx < trackFragmentList.count else { break }
            let f = trackFragmentList[idx]
            out.append(f)
            if f.link == 0 { break }
            idx = f.link
            guardCount += 1
            if guardCount > 256 { break } // Malformed TOC guard.
        }
        return out
    }

    public func title(forTrack track: Int) -> String? {
        guard track >= 1, track < titleMap.count else { return nil }
        var cell = titleMap[track]
        var bytes = [UInt8]()
        var depth = 0
        while cell != 0 && depth < 10 {
            guard cell < titleCellList.count else { break }
            bytes += titleCellList[cell].title
            cell = titleCellList[cell].link
            depth += 1
        }
        if let zero = bytes.firstIndex(of: 0) { bytes = Array(bytes[..<zero]) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// The on-disc track format, decoded from a fragment's mode flags.
public enum RecoveredFormat: String { case sp = "SPS", spMono = "SPM", lp2 = "LP2", lp4 = "LP4" }

public func recoveredFormat(for fragment: TOCFragment) -> RecoveredFormat {
    let stereo = fragment.mode & ModeFlag.stereo != 0
    let sp = fragment.mode & ModeFlag.spMode != 0
    switch (stereo, sp) {
    case (true, true): return .sp
    case (false, true): return .spMono
    case (true, false): return .lp2
    case (false, false): return .lp4
    }
}
