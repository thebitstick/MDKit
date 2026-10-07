import Foundation

/// Drives one "homebrew mode" ripping session: authenticates into factory mode, detects the
/// exact firmware version, activates `USBCodeExecution`, and downloads tracks via the no-RAM
/// sector-recovery backend. This is the orchestration layer the app UI talks to.
public final class HomebrewRipper {
    public let iface: NetMDInterface
    public let factory: FactoryInterface
    public private(set) var versionCode: String = ""
    public private(set) var backendDescription: String = ""
    private var exec: USBCodeExecution?
    private var toc: UTOC?
    private var controlBackendInstalled = false

    /// Patch slots reserved for the control-transfer backend's two firmware redirects (slot 0 is
    /// `USBCodeExecution`'s own trampoline).
    private static let controlPatchSlot1 = 1, controlPatchSlot2 = 2

    public init(_ iface: NetMDInterface) {
        self.iface = iface
        self.factory = FactoryInterface(iface)
    }

    /// Firmware families known to support no-RAM ATRAC recovery (mirrors netmd-exploits'
    /// compatibility table for `CachedSectorNoRamControlDownload`).
    public static let supportedVersions: Set<String> = [
        "S1.600", "S1.500", "S1.400", "S1.300", "S1.200", "S1.100", "S1.000",
        "R1.400", "R1.300", "R1.200", "R1.100", "R1.000",
    ]

    /// Authenticates into factory mode and identifies the firmware. Throws if this exact
    /// firmware version isn't one ripping has been implemented/tested for.
    @discardableResult
    public func connect() throws -> String {
        try factory.auth()
        let version = try factory.descriptiveVersion()
        guard Self.supportedVersions.contains(version) else {
            throw NetMDError.unsupported("Homebrew mode ripping doesn't support this unit's firmware (\(version)).")
        }
        versionCode = version
        let maxSlots = version.hasPrefix("R") ? 4 : 8
        let e = USBCodeExecution(factory: factory, iface: iface, versionCode: version, maxSlots: maxSlots)
        try e.activate()
        exec = e
        backendDescription = FirmwareAssembler.controlAddresses[version] != nil ? "control-transfer (fast)" : "no-RAM (slow)"
        return version
    }

    public func disconnect() {
        if controlBackendInstalled {
            try? factory.unpatch(slot: Self.controlPatchSlot1, maxSlots: 8)
            try? factory.unpatch(slot: Self.controlPatchSlot2, maxSlots: 8)
            controlBackendInstalled = false
        }
        exec?.deactivate()
        exec = nil
    }

    /// Reads (and caches) the UTOC fragment table, needed to know each track's physical extent.
    public func readTOC() throws -> UTOC {
        if let toc { return toc }
        let s0 = try factory.readUTOCSector(0)
        let s1 = try? factory.readUTOCSector(1)
        let parsed = try UTOC.parse(sector0: s0, sector1: s1)
        toc = parsed
        return parsed
    }

    /// Installs the control-transfer backend's resident handler and both redirect patches, all in
    /// one atomic injected run (see `FirmwareAssembler.assembleControlInstaller`) — applying the
    /// two patches as separate host-side steps would leave a window where the firmware's own
    /// background USB polling could hit a half-installed redirect and hang the deck.
    private func installControlBackend(_ exec: USBCodeExecution) throws {
        guard !controlBackendInstalled else { return }
        let installer = try FirmwareAssembler.assembleControlInstaller(for: versionCode, maxSlots: 8)
        // Generous reply-length margin, like the activation probe: this program doesn't read back
        // any synthesized value, so exactness doesn't matter, only not under-requesting.
        _ = try exec.execute(installer, replyLength: installer.count + 64)
        controlBackendInstalled = true
    }

    /// Downloads one track (0-indexed) and returns ready-to-save file data plus the extension
    /// it should be saved with ("aea" for SP, "wav" for LP2/LP4). Prefers the fast control-transfer
    /// backend when this firmware supports it (S* only — upstream found Type-R decks become
    /// unstable with it), falling back to the slower no-RAM backend otherwise.
    public func downloadTrack(
        _ track: Int,
        config: RecoveryConfig = RecoveryConfig(),
        progress: ((RecoveryProgress) -> Void)? = nil,
        isCancelled: @escaping () -> Bool = { false }
    ) throws -> (data: [UInt8], fileExtension: String) {
        guard let exec else { throw NetMDError.usb("Not connected to factory mode") }
        let toc = try readTOC()
        let backend: SectorRecoveryBackend
        if FirmwareAssembler.controlAddresses[versionCode] != nil {
            try installControlBackend(exec)
            backend = ControlSectorBackend(factory: factory, versionCode: versionCode)
        } else {
            backend = try NoRamSectorBackend(exec: exec, versionCode: versionCode)
        }
        return try ATRACRecovery.downloadTrack(
            track, toc: toc, backend: backend, iface: iface, factory: factory, versionCode: versionCode,
            config: config, progress: progress, isCancelled: isCancelled
        )
    }
}

/// Reads sectors via the standard NetMD reply channel, after the firmware's own USB-reply routine
/// has been redirected (see `HomebrewRipper.installControlBackend`) to serve raw ATRAC sectors
/// instead of its normal response whenever `enabledFlag` is set. No per-chunk round-trips — each
/// sector is one `readReply(2352)` — which is what makes this fast enough to keep up with the
/// drive's live DRAM cache. Ported from netmd-exploits' `CachedSectorControlDownload`.
final class ControlSectorBackend: SectorRecoveryBackend {
    private let factory: FactoryInterface
    private let iface: NetMDInterface
    private let addresses: FirmwareAssembler.ControlAddresses
    private var active = false

    init(factory: FactoryInterface, versionCode: String) {
        self.factory = factory
        self.iface = factory.iface
        // installControlBackend already validated this version is known before constructing us.
        self.addresses = FirmwareAssembler.controlAddresses[versionCode]!
    }

    func startDownload(track: Int) throws {
        try? factory.setDisplayOverride("ACCESS", blink: true)
        try factory.write(address: addresses.enabledFlag, data: leWord(1))
        active = true
    }

    func finishDownload() throws {
        try? factory.setDisplayMode(.standard)
        try factory.write(address: addresses.enabledFlag, data: leWord(0))
        active = false
    }

    func setSectorToRead(_ sector: Int, remaining: Int) throws {
        try factory.write(address: addresses.sectorToRead, data: leWord(sector))
    }

    func readNextSector() throws -> [UInt8] {
        guard active else { throw NetMDError.protocolError("startDownload() was not called") }
        // Fixed-length read, like USBCodeExecution's: 2352 can't be represented in the normal
        // single-byte announced-length protocol, so this bypasses it, matching upstream exactly
        // (`netMd.readReply(2352)` there too).
        return try iface.transport.readReplyFixedLength(2352)
    }
}

/// Reads DRAM sectors by repeatedly executing a small assembled stub via `USBCodeExecution`,
/// pulling a few hundred bytes per call (ARM code-execution replies are size-limited), and
/// reassembling the 2352-byte CD sector from those pieces. Ported from netmd-exploits'
/// `CachedSectorNoRamControlDownload` — the slowest of the three available backends, but the one
/// that needs no persistent firmware patch while actually transferring data.
///
/// Each chunk is requested as `want + codeLength + 4` bytes; `USBCodeExecution.execute` already
/// strips the fixed 4-byte `08 18<cmd> ff` reply envelope, leaving `want + codeLength` bytes, of
/// which the first `codeLength` are the stub's own echoed-back code and get dropped here too,
/// leaving exactly `want` bytes of real sector data per chunk — no surplus or overshoot.
final class NoRamSectorBackend: SectorRecoveryBackend {
    private let exec: USBCodeExecution
    private let template: FirmwareAssembler.NoRamTemplate
    private var sector = 0
    private var active = false

    init(exec: USBCodeExecution, versionCode: String) throws {
        self.exec = exec
        self.template = try FirmwareAssembler.noRamTemplate(for: versionCode)
    }

    func startDownload(track: Int) throws { active = true }
    func finishDownload() throws { active = false }
    func setSectorToRead(_ s: Int, remaining: Int) throws { sector = s }

    func readNextSector() throws -> [UInt8] {
        guard active else { throw NetMDError.protocolError("startDownload() was not called") }
        let maxPayload = 512 - 8 - template.codeLength
        var out = [UInt8]()
        var remaining = 2352
        while remaining > 0 {
            let want = min(remaining, maxPayload)
            let code = template.makeCode(sector: sector, subsectorStart: 2352 - remaining, length: want)
            let reply = try exec.execute(code, replyLength: want + template.codeLength + 4)
            let data = reply.suffix(from: min(template.codeLength, reply.count))
            out += data
            remaining -= data.count
        }
        sector += 1
        return out
    }
}
