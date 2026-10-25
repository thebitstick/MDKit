import Foundation
import AppKit
import SwiftUI
import NetMDKit

struct UploadItem: Identifiable {
    enum State: Equatable {
        case pending
        case preparing(String)
        case sending(Double)
        case done
        case failed(String)
        case cancelled
    }
    let id = UUID()
    var url: URL
    var title: String
    var artist: String
    var mode: RecordingMode
    var duration: Double
    var state: State = .pending

    /// Approximate time this item will take on the disc, in seconds.
    var discSeconds: Double { duration * mode.discTimeFactor }
}

struct RipItem: Identifiable {
    enum State: Equatable {
        case pending
        case downloading(Double)
        case done(URL)
        case failed(String)
        case cancelled
    }
    let id = UUID()
    var index: Int
    var title: String
    var format: String
    var seconds: Double
    var state: State = .pending
}

/// Whether "homebrew mode" factory-mode ripping is usable on the connected unit — only known
/// after actually authenticating into factory mode and reading the exact firmware version.
enum RipperReadiness: Equatable {
    case unknown
    case checking
    case ready(firmwareVersion: String)
    case unavailable(String)
}

/// Owns the USB connection and serialises every device operation on a background queue.
@MainActor
final class DeviceController: ObservableObject {
    @Published var attached: [AttachedDevice] = []
    @Published var connected: AttachedDevice?
    @Published var disc: Disc?
    @Published var status: DeviceStatus?
    @Published var busy: String?
    @Published var errorMessage: String?
    @Published var queue: [UploadItem] = []
    @Published var defaultMode: RecordingMode = .sp
    @Published var isUploading = false

    private let io = DispatchQueue(label: "mdkit.netmd.io", qos: .userInitiated)
    private var iface: NetMDInterface?
    private var pollTimer: Timer?
    private var cancelUpload = false
    private var activeOps = 0
    /// Set by an explicit Disconnect; suppresses auto-reconnect to this device until it is
    /// unplugged (or the user picks it again from the connect screen).
    private var declinedAutoConnect: AttachedDevice?
    let encoderAvailable = AudioImporter.locateEncoder() != nil

    // MARK: Homebrew-mode ripping

    @Published var ripperReadiness: RipperReadiness = .unknown
    @Published var ripItems: [RipItem] = []
    @Published var isRipping = false
    /// Diagnostic escape hatch: skip the ATRAC frame-validity gate so a run doesn't abort on the
    /// first sector that fails it, to see how much of a track actually comes through regardless.
    @Published var skipAtracValidation = false
    private var ripper: HomebrewRipper?
    private var cancelRip = false

    init() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
        Task { await poll() }
        // Quitting mid-rip would leave the deck's firmware redirect enabled, and a deck in that state
        // stops answering everything until it is power-cycled. Stop the rip first so it clears the flag.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopRippingBeforeQuit() }
        }
    }

    /// Cancels an in-progress rip and waits (bounded) for it to unwind and clear the redirect. Spins the
    /// run loop rather than blocking, because the rip's cancellation check hops through the main queue.
    private func stopRippingBeforeQuit() {
        guard isRipping else { return }
        cancelRip = true
        let deadline = Date().addingTimeInterval(15)
        while isRipping, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    // MARK: Worker plumbing

    @discardableResult
    private func perform<T: Sendable>(_ label: String? = nil, _ body: @escaping @Sendable (NetMDInterface) throws -> T) async throws -> T {
        guard let iface else { throw NetMDError.usb("No recorder connected") }
        activeOps += 1
        if let label { busy = label }
        defer {
            activeOps -= 1
            if activeOps == 0 { busy = nil }
        }
        let box = iface
        return try await withCheckedThrowingContinuation { cont in
            io.async {
                do { cont.resume(returning: try body(box)) } catch { cont.resume(throwing: error) }
            }
        }
    }

    private func report(_ error: Error) {
        if case NetMDError.cancelled = error { return }
        errorMessage = error.localizedDescription
        // A vanished device surfaces as USB errors; drop the connection so the UI recovers.
        if case NetMDError.usb = error { Task { await verifyConnection() } }
    }

    private func verifyConnection() async {
        let now = await Task.detached { NetMDTransport.attachedDevices() }.value
        attached = now
        if let c = connected, !now.contains(c) { disconnect() }
    }

    // MARK: Connection

    private func poll() async {
        if activeOps == 0 {
            let now = await Task.detached { NetMDTransport.attachedDevices() }.value
            if now != attached { attached = now }
            if let c = connected, !now.contains(c) { disconnect() }
            if let declined = declinedAutoConnect, !now.contains(declined) { declinedAutoConnect = nil }
            if connected == nil, let first = now.first, first != declinedAutoConnect,
               UserDefaults.standard.bool(forKey: "autoConnect") || now.count == 1 {
                await connect(first)
            }
        }
        if connected != nil, activeOps == 0, !isUploading, !isRipping {
            let polled = try? await perform { try $0.deviceStatus() }
            if let s = polled {
                let hadDisc = status?.discPresent ?? false
                status = s
                if s.discPresent && (!hadDisc || disc == nil) && ![.readingTOC].contains(s.state) { await refresh() }
                if !s.discPresent { disc = nil }
            }
        }
    }

    func connect(_ device: AttachedDevice) async {
        guard connected == nil else { return }
        declinedAutoConnect = nil // An explicit connect (even to the declined device) always proceeds.
        busy = "Connecting to \(device.name)…"
        defer { busy = nil }
        do {
            let box: NetMDInterface = try await withCheckedThrowingContinuation { cont in
                io.async {
                    do {
                        let t = try NetMDTransport(device: device)
                        cont.resume(returning: NetMDInterface(transport: t))
                    } catch { cont.resume(throwing: error) }
                }
            }
            iface = box
            connected = device
            _ = try? await perform { try $0.netMDLevel() }
            await refresh()
        } catch {
            errorMessage = Self.stuckHint(error) ?? error.localizedDescription
        }
    }

    /// A deck whose cable was pulled mid-rip keeps its firmware redirect enabled and stops answering
    /// everything until it loses power, which surfaces as USB timeouts.
    private static func stuckHint(_ error: Error) -> String? {
        guard case NetMDError.usb(let m) = error, m.contains("timed out") else { return nil }
        return "\(error.localizedDescription). If a rip was interrupted (for example the cable was pulled), the deck is stuck in ripping mode: remove its batteries or power adapter for a few seconds, then reconnect."
    }

    private static func ripFailureMessage(_ error: Error) -> String {
        if let hint = stuckHint(error) { return hint }
        if case NetMDError.usb = error {
            return "\(error.localizedDescription). The deck may now be stuck in ripping mode: if it stops responding, remove its batteries or power adapter for a few seconds."
        }
        return error.localizedDescription
    }

    func disconnect() {
        // Let an in-progress rip unwind (and clear the firmware redirect) before the connection closes.
        if isRipping { cancelRip = true }
        let old = iface
        let oldRipper = ripper
        ripper = nil
        ripperReadiness = .unknown
        ripItems = []
        declinedAutoConnect = connected
        iface = nil
        connected = nil
        disc = nil
        status = nil
        io.async { oldRipper?.disconnect(); old?.transport.close() }
    }

    // MARK: Disc

    func refresh() async {
        do {
            let d = try await perform("Reading disc…") { try $0.listContent() }
            disc = d
        } catch NetMDError.rejected {
            disc = nil // Usually "no disc inserted".
        } catch {
            report(error)
        }
    }

    func renameDisc(_ name: String) async {
        await edit("Renaming disc…") { try $0.renameDisc(name) }
    }

    func renameTrack(_ track: Track, to name: String) async {
        await edit("Renaming track…") { try $0.setTrackTitle(track.index, title: name) }
    }

    func deleteTracks(_ indices: [Int]) async {
        guard let snapshot = disc, !indices.isEmpty else { return }
        await edit("Deleting…") { iface in
            var d = snapshot
            try iface.deleteTracks(indices)
            // Group ranges refer to track numbers, which just shifted.
            let remaining = d.allTracks.filter { !indices.contains($0.index) }.map(\.index)
            let map = Dictionary(uniqueKeysWithValues: remaining.enumerated().map { ($1, $0) })
            d.groups = d.groups.map { g in
                var g = g
                g.tracks = g.tracks.filter { map[$0.index] != nil }.map { var t = $0; t.index = map[t.index]!; return t }
                return g
            }
            d.trackCount = remaining.count
            try iface.rewriteDiscGroups(d)
        }
    }

    func eraseDisc() async { await edit("Erasing disc…") { try $0.eraseDisc() } }

    func eject() async {
        await edit("Ejecting…") { try $0.ejectDisc() }
        disc = nil
    }

    /// Re-lays out groups and track order. `groups` uses current device indices; ungrouped has `title == nil`.
    func commitLayout(_ groups: [DiscGroup]) async {
        guard let current = disc else { return }
        let ungrouped = groups.filter { $0.title == nil }.flatMap(\.tracks)
        let named = groups.filter { $0.title != nil && !$0.tracks.isEmpty }
        let order = (ungrouped + named.flatMap(\.tracks)).map(\.index)
        var base = current

        var position = 0
        func reindexed(_ tracks: [Track]) -> [Track] {
            tracks.map { var t = $0; t.index = position; position += 1; return t }
        }
        var newGroups = [DiscGroup]()
        if !ungrouped.isEmpty { newGroups.append(DiscGroup(index: 0, title: nil, fullWidthTitle: nil, tracks: reindexed(ungrouped))) }
        for g in named { newGroups.append(DiscGroup(index: newGroups.count, title: g.title, fullWidthTitle: g.fullWidthTitle, tracks: reindexed(g.tracks))) }
        base.groups = newGroups
        let layout = base

        await edit("Updating groups…") { iface in
            try iface.applyTrackOrder(order)
            try iface.rewriteDiscGroups(layout)
        }
    }

    private func edit(_ label: String, _ body: @escaping @Sendable (NetMDInterface) throws -> Void) async {
        do {
            try await perform(label, body)
            await refresh()
        } catch { report(error) }
    }

    // MARK: Transport

    func transport(_ action: @escaping @Sendable (NetMDInterface) throws -> Void) async {
        do { try await perform(nil, action); status = try? await perform { try $0.deviceStatus() } } catch { report(error) }
    }

    func play(track: Int) async {
        await transport { _ = try $0.gotoTrack(track); try $0.play() }
    }

    // MARK: Uploads

    func enqueue(_ urls: [URL]) async {
        for url in urls {
            let meta = await AudioImporter.metadata(for: url)
            queue.append(UploadItem(url: url, title: meta.title, artist: meta.artist, mode: defaultMode, duration: meta.duration))
        }
    }

    var pendingDiscSeconds: Double { queue.filter { $0.state == .pending }.map(\.discSeconds).reduce(0, +) }
    var discSecondsLeft: Double? { disc.map { Double($0.left) / 512.0 } }

    func clearFinished() {
        queue.removeAll {
            switch $0.state { case .done, .failed, .cancelled: return true; default: return false }
        }
    }

    func cancelUploads() { cancelUpload = true }

    func startUploads() async {
        guard connected != nil, !isUploading else { return }
        isUploading = true
        cancelUpload = false
        defer { isUploading = false; busy = nil }

        while let i = queue.firstIndex(where: { $0.state == .pending }), !cancelUpload {
            let item = queue[i]
            let id = item.id
            func set(_ s: UploadItem.State) { if let k = queue.firstIndex(where: { $0.id == id }) { queue[k].state = s } }

            do {
                busy = "Uploading “\(item.title)”…"
                let cancelled = { [weak self] in self?.cancelUpload ?? true }
                set(.preparing("Decoding…"))
                let prepared = try await Task.detached(priority: .userInitiated) { [item] in
                    try AudioImporter.prepare(url: item.url, title: item.title, mode: item.mode, isCancelled: { DispatchQueue.main.sync { cancelled() } },
                                              stage: { s in Task { @MainActor in set(.preparing(s)) } })
                }.value

                set(.sending(0))
                try await perform { iface in
                    try iface.upload(prepared, isCancelled: { DispatchQueue.main.sync { cancelled() } }) { p in
                        Task { @MainActor in set(.sending(p.fraction)) }
                    }
                }
                set(.done)
            } catch NetMDError.cancelled {
                set(.cancelled)
            } catch {
                set(.failed(error.localizedDescription))
                // A failed transfer leaves the unit in an unknown state; stop the batch.
                break
            }
        }
        await refresh()
    }

    // MARK: Homebrew-mode ripping

    private func performRipper<T: Sendable>(_ body: @escaping @Sendable (HomebrewRipper) throws -> T) async throws -> T {
        guard let ripper else { throw NetMDError.usb("Homebrew ripping was not initialized") }
        activeOps += 1
        defer { activeOps -= 1; if activeOps == 0 { busy = nil } }
        let box = ripper
        return try await withCheckedThrowingContinuation { cont in
            io.async {
                do { cont.resume(returning: try body(box)) } catch { cont.resume(throwing: error) }
            }
        }
    }

    /// Authenticates into factory mode and identifies the firmware, so the UI can show whether
    /// ripping is possible on this unit before the user picks tracks.
    func prepareRipping() async {
        guard let iface else { ripperReadiness = .unavailable("Not connected"); return }
        if case .ready = ripperReadiness { return } // Already prepared this session.
        ripperReadiness = .checking
        let ifaceBox = iface
        do {
            let (newRipper, version): (HomebrewRipper, String) = try await withCheckedThrowingContinuation { cont in
                io.async {
                    do {
                        let r = HomebrewRipper(ifaceBox)
                        let v = try r.connect()
                        cont.resume(returning: (r, v))
                    } catch { cont.resume(throwing: error) }
                }
            }
            ripper = newRipper
            ripperReadiness = .ready(firmwareVersion: version)
        } catch {
            ripperReadiness = .unavailable(error.localizedDescription)
        }
    }

    private func setRip(_ id: UUID, _ state: RipItem.State) {
        if let i = ripItems.firstIndex(where: { $0.id == id }) { ripItems[i].state = state }
    }

    func cancelRipping() { cancelRip = true }

    /// Downloads `trackIndices` (0-indexed, as in `Disc.allTracks`) to individual files in
    /// `folder`, named after each track's title with the appropriate extension (`.aea` for SP,
    /// `.wav` for LP2/LP4).
    func startRipping(_ trackIndices: [Int], to folder: URL) async {
        guard ripper != nil, !isRipping else { return }
        isRipping = true
        cancelRip = false
        defer { isRipping = false; busy = nil }

        let tracksByIndex = Dictionary(uniqueKeysWithValues: (disc?.allTracks ?? []).map { ($0.index, $0) })
        ripItems = trackIndices.map { i in
            let t = tracksByIndex[i]
            let title = (t?.title.isEmpty == false ? t?.title : nil) ?? "Track \(i + 1)"
            return RipItem(index: i, title: title, format: t?.encoding.label ?? "", seconds: t?.seconds ?? 0)
        }

        for item in ripItems {
            let id = item.id
            if cancelRip { setRip(id, .cancelled); continue }
            busy = "Ripping “\(item.title)”…"
            setRip(id, .downloading(0))
            let cancelled = { [weak self] in self?.cancelRip ?? true }
            let config: RecoveryConfig = {
                var c = RecoveryConfig()
                c.verifyValidAtrac = !skipAtracValidation
                return c
            }()
            do {
                let result: (data: [UInt8], fileExtension: String) = try await performRipper { ripper in
                    var r = try ripper.downloadTrack(item.index, config: config, progress: { p in
                        let fraction = p.total > 0 ? Double(p.read) / Double(p.total) : 0
                        Task { @MainActor in self.setRip(id, .downloading(fraction)) }
                    }, isCancelled: { DispatchQueue.main.sync { cancelled() } })
                    // SP rips come out as AEA (raw ATRAC1), which nothing on macOS can play
                    // natively. Decode to a real WAV via ffmpeg when available so the saved file
                    // is actually playable; if ffmpeg is missing or decoding fails, keep the AEA.
                    if r.fileExtension == "aea", let wav = try? ATRACDecoding.decodeAEAToWAV(r.data) {
                        r = (wav, "wav")
                    }
                    return r
                }
                let safeName = item.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
                var url = folder.appendingPathComponent(safeName).appendingPathExtension(result.fileExtension)
                var n = 2
                while FileManager.default.fileExists(atPath: url.path) {
                    url = folder.appendingPathComponent("\(safeName) \(n)").appendingPathExtension(result.fileExtension)
                    n += 1
                }
                try Data(result.data).write(to: url)
                setRip(id, .done(url))
            } catch NetMDError.cancelled {
                setRip(id, .cancelled)
            } catch {
                setRip(id, .failed(Self.ripFailureMessage(error)))
                // A failed rip can leave the deck mid-seek or mid-realignment; stopping here
                // (like startUploads does on failure) is safer than racing straight into another
                // track's factory-mode sequence on top of that unknown state.
                for remaining in ripItems where remaining.id != id {
                    if case .pending = remaining.state { setRip(remaining.id, .cancelled) }
                    if case .downloading = remaining.state { setRip(remaining.id, .cancelled) }
                }
                break
            }
        }
    }
}
