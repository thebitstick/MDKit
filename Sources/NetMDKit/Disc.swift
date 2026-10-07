import Foundation

public struct Track: Identifiable, Hashable, Sendable {
    public var index: Int
    public var title: String
    public var fullWidthTitle: String
    /// Duration in 1/512-second frames.
    public var duration: Int
    public var channel: Channels
    public var encoding: Encoding
    public var isProtected: Bool
    public var id: Int { index }

    public var seconds: Double { Double(duration) / 512.0 }

    public init(index: Int, title: String, fullWidthTitle: String, duration: Int, channel: Channels, encoding: Encoding, isProtected: Bool) {
        self.index = index; self.title = title; self.fullWidthTitle = fullWidthTitle; self.duration = duration
        self.channel = channel; self.encoding = encoding; self.isProtected = isProtected
    }
}

public struct DiscGroup: Identifiable, Hashable, Sendable {
    public var index: Int
    public var title: String?
    public var fullWidthTitle: String?
    public var tracks: [Track]
    public var id: Int { index }

    public init(index: Int, title: String?, fullWidthTitle: String?, tracks: [Track]) {
        self.index = index; self.title = title; self.fullWidthTitle = fullWidthTitle; self.tracks = tracks
    }
}

public struct Disc: Sendable {
    public var title: String
    public var fullWidthTitle: String
    public var writable: Bool
    public var writeProtected: Bool
    public var used: Int
    public var left: Int
    public var total: Int
    public var trackCount: Int
    public var groups: [DiscGroup]

    public var allTracks: [Track] { groups.flatMap { $0.tracks } }

    public init(title: String, fullWidthTitle: String, writable: Bool, writeProtected: Bool, used: Int, left: Int, total: Int, trackCount: Int, groups: [DiscGroup]) {
        self.title = title; self.fullWidthTitle = fullWidthTitle; self.writable = writable; self.writeProtected = writeProtected
        self.used = used; self.left = left; self.total = total; self.trackCount = trackCount; self.groups = groups
    }
}

public func timeToFrames(_ t: [Int]) -> Int {
    guard t.count == 4 else { return 0 }
    return ((t[0] * 60 + t[1]) * 60 + t[2]) * 512 + t[3]
}

public enum DeviceState: String, Sendable { case ready, playing, paused, fastForward, rewind, readingTOC, noDisc, discBlank, readyForTransfer, unknown }

public struct DeviceStatus: Sendable {
    public var discPresent: Bool
    public var state: DeviceState
    public var track: Int?
    /// Elapsed time in seconds.
    public var elapsed: Double?
}

extension NetMDInterface {
    public func deviceStatus() throws -> DeviceStatus {
        let status = try getStatus()
        let pb = try getPlaybackStatus2()
        let op = pb.count > 5 ? Int(pb[4]) << 8 | Int(pb[5]) : 0
        let position = try getPosition()
        let discPresent = status.count > 4 && status[4] != 0x80

        let table: [Int: DeviceState] = [
            50687: .ready, 50037: .playing, 50045: .paused, 49983: .fastForward, 49999: .rewind,
            65315: .readingTOC, 65296: .noDisc, 65535: .discBlank, 65319: .readyForTransfer,
        ]
        var state = table[op] ?? .unknown
        if state == .playing && !discPresent { state = .ready }
        var elapsed: Double?
        if let p = position, p.count >= 5 { elapsed = Double(p[2] * 60 + p[3]) + Double(p[1]) * 3600 + Double(p[4]) / 512.0 }
        return DeviceStatus(discPresent: discPresent && ![.readingTOC, .noDisc].contains(state), state: state,
                            track: position?[0], elapsed: elapsed)
    }

    public func listContent() throws -> Disc {
        let flags = try getDiscFlags()
        let title = try discTitle()
        let fullTitle = try discTitle(wide: true)
        let cap = try discCapacity()
        let count = try getTrackCount()

        var used = timeToFrames(cap[0]), total = timeToFrames(cap[1]), left = timeToFrames(cap[2])
        // Some devices (Sharps) report capacity for the selected recording mode.
        while total > 512 * 60 * 82 && total > 0 { used /= 2; total /= 2; left /= 2 }

        var disc = Disc(title: title, fullWidthTitle: fullTitle,
                        writable: flags & DiscFlag.writable != 0, writeProtected: flags & DiscFlag.writeProtected != 0,
                        used: used, left: left, total: total, trackCount: count, groups: [])

        for (gi, g) in try trackGroupList().enumerated() {
            var group = DiscGroup(index: gi, title: g.name, fullWidthTitle: g.fullWidthName, tracks: [])
            for t in g.tracks {
                let enc = try trackEncoding(t)
                let dur = timeToFrames(try trackLength(t))
                let fl = try trackFlags(t)
                group.tracks.append(Track(
                    index: t, title: try trackTitle(t), fullWidthTitle: try trackTitle(t, wide: true), duration: dur,
                    channel: Channels(rawValue: enc[1]) ?? .stereo, encoding: Encoding(rawValue: enc[0]) ?? .sp,
                    isProtected: fl == TrackFlag.protected.rawValue))
            }
            disc.groups.append(group)
        }
        return disc
    }
}

// MARK: - Title budget & group markup (port of netmd-commands.ts)

public enum DiscTitles {
    static func cells(_ len: Int) -> Int { Int(ceil(Double(len) / 7.0)) }

    static func cellsForTitle(_ t: Track) -> (half: Int, full: Int) {
        let corr = t.encoding == .sp ? 0 : 1
        return (max(corr, cells(Titles.halfWidthLength(t.title))), max(corr, cells(t.fullWidthTitle.count * 2)))
    }

    static func rangeLength(_ g: DiscGroup) -> String {
        let idx = g.tracks.map(\.index)
        guard let lo = idx.min(), let hi = idx.max() else { return "" }
        return "\(lo + 1)" + (g.tracks.count > 1 ? "-\(hi + 1)" : "") + "//"
    }

    public static func remainingCharacters(_ disc: Disc, includeGroups: Bool = true) -> (half: Int, full: Int) {
        var fw = disc.fullWidthTitle + "0;//"
        var hw = disc.title + "0;//"
        if includeGroups {
            for g in disc.groups where g.title != nil && !g.tracks.isEmpty {
                let r = rangeLength(g)
                fw += (g.fullWidthTitle ?? "") + r
                hw += (g.title ?? "") + r
            }
        }
        var usedHalf = cells(Titles.halfWidthLength(hw))
        var usedFull = cells(fw.count * 2)
        for t in disc.allTracks { let c = cellsForTitle(t); usedHalf += c.half; usedFull += c.full }
        return (max(255 - usedHalf, 0) * 7, max(255 - usedFull, 0) * 7)
    }

    /// Builds the raw half- and full-width disc title strings, including group ranges.
    public static func compile(_ disc: Disc) -> (half: String, full: String) {
        var bare = disc
        bare.title = ""; bare.fullWidthTitle = ""
        let avail = remainingCharacters(bare, includeGroups: false)

        let useFull = !disc.fullWidthTitle.isEmpty
            || disc.groups.contains { !($0.fullWidthTitle ?? "").isEmpty }
            || disc.allTracks.contains { !$0.fullWidthTitle.isEmpty }

        var rawHalf = "", rawFull = ""
        if !disc.title.isEmpty { rawHalf = "0;\(disc.title)//" }
        if useFull { rawFull = "０；\(disc.fullWidthTitle)／／" }
        var hits = 0

        for g in disc.groups {
            guard let gTitle = g.title, !g.tracks.isEmpty else { continue }
            hits += 1
            let lo = g.tracks.map(\.index).min()!
            var range = "\(lo + 1)"
            if g.tracks.count != 1 { range += "-\(lo + g.tracks.count)" }

            let halfAfter = rawHalf + "\(range);\(gTitle)//"
            let fullAfter = rawFull + Titles.halfWidthToFullWidthRange(range) + "；\(g.fullWidthTitle ?? "")／／"
            let halfBytes = cells(Titles.halfWidthLength(halfAfter)) * 7
            if useFull, avail.full - cells(fullAfter.count * 2) * 7 >= 0 { rawFull = fullAfter }
            if avail.half - halfBytes >= 0 { rawHalf = halfAfter }
        }
        if hits == 0 { rawHalf = disc.title; rawFull = disc.fullWidthTitle }
        if avail.half - cells(Titles.halfWidthLength(rawHalf)) * 7 < 0 { rawHalf = "" }
        if avail.full - cells(rawFull.count * 2) < 0 { rawFull = "" }
        return (rawHalf, useFull ? rawFull : "")
    }
}

extension NetMDInterface {
    public func rewriteDiscGroups(_ disc: Disc) throws {
        let c = DiscTitles.compile(disc)
        try setDiscTitle(c.half)
        try setDiscTitle(c.full, wide: true)
    }

    /// Renames the disc while preserving existing group markup.
    public func renameDisc(_ newName: String, fullWidth newFull: String? = nil) throws {
        let name = Titles.sanitizeHalfWidth(newName)
        let oldName = try discTitle()
        let oldFull = try discTitle(wide: true)
        let rawName = try rawDiscTitle()
        let rawFull = try rawDiscTitle(wide: true)
        let hasGroups = rawName.contains("//")
        let hasFullGroups = rawName.contains("／／")
        let hasGroupsAndTitle = rawName.hasPrefix("0;")
        let hasFullGroupsAndTitle = rawName.hasPrefix("０；")

        if let newFull {
            let full = Titles.sanitizeFullWidth(newFull)
            if full != oldFull {
                var composed = full
                if hasFullGroups {
                    if hasFullGroupsAndTitle {
                        composed = rawFull.replacingFirst(pattern: "^０；.*?／／", with: full.isEmpty ? "" : "０；\(full)／／")
                    } else {
                        composed = "０；\(full)／／\(rawFull)"
                    }
                }
                try setDiscTitle(composed, wide: true)
            }
        }
        if name == oldName { return }
        var composed = name
        if hasGroups {
            composed = hasGroupsAndTitle
                ? rawName.replacingFirst(pattern: "^0;.*?//", with: name.isEmpty ? "" : "0;\(name)//")
                : "0;\(name)//\(rawName)"
        }
        try setDiscTitle(composed)
    }

    /// Reorders device tracks to match `order` (current device indices in desired sequence).
    public func applyTrackOrder(_ order: [Int]) throws {
        var current = Array(0..<order.count)
        for pos in 0..<order.count where current[pos] != order[pos] {
            guard let j = current.firstIndex(of: order[pos]) else { continue }
            try moveTrack(from: j, to: pos)
            let v = current.remove(at: j)
            current.insert(v, at: pos)
        }
    }

    public func deleteTracks(_ indices: [Int]) throws {
        for t in indices.sorted(by: >) { try eraseTrack(t) }
    }
}

extension String {
    fileprivate func replacingFirst(pattern: String, with replacement: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let m = re.firstMatch(in: self, range: NSRange(startIndex..., in: self)),
              let r = Range(m.range, in: self) else { return self }
        return replacingCharacters(in: r, with: replacement)
    }
}
