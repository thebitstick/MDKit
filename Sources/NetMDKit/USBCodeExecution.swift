import Foundation

/// Arbitrary-code-execution primitive used by every "homebrew mode" feature. It works by
/// patching one firmware function's entry point (a fixed, publicly documented RAM address per
/// firmware version — no vulnerability involved) to jump into a small stub that lets the host
/// hand the device a block of machine code to run and read the result of. Ported 1:1 from
/// netmd-exploits' `USBCodeExecution` (the `onePatchAddress`/`onePatchValue` tables below are
/// copied verbatim; they're pre-assembled constants, not generated).
///
/// This only works for S*/R*/Hr*/Hn*/Hx* non-HiMD-portable firmware (`CompatibleVersions`).
public final class USBCodeExecution {
    private let factory: FactoryInterface
    private let iface: NetMDInterface
    private let versionCode: String
    private var patchSlot: Int?
    private let maxSlots: Int

    public static let compatibleVersions: Set<String> = [
        "S1.600", "S1.500", "S1.400", "S1.300", "S1.200", "S1.100", "S1.000",
        "R1.400", "R1.300", "R1.200", "R1.100", "R1.000",
        "Hr1.000", "Hn1.000", "Hn1.100", "Hn1.10A", "Hn1.200",
        "Hx1.0A0", "Hx1.090", "Hx1.080", "Hx1.070", "Hx1.060", "Hx1.040",
    ]

    public static func isSupported(_ version: String) -> Bool { compatibleVersions.contains(version) }

    // 2-instruction THUMB trampoline ("ldr r0, [pc, #N]; bx r0") written over the start of a
    // function the firmware calls constantly, redirecting it into the resident command handler.
    private static let patchAddress: [String: Int] = [
        "S1.600": 0x0000e69c, "S1.500": 0x0000e538, "S1.400": 0x0000e4c4, "S1.300": 0x0000daa8,
        "S1.200": 0x0000d834, "S1.100": 0x0000d784, "S1.000": 0x0000e784,
        "R1.000": 0x00056228, "R1.100": 0x00056aac, "R1.200": 0x000577f8, "R1.300": 0x00057b48, "R1.400": 0x00057be8,
        "Hr1.000": 0x000989f0,
        "Hn1.000": 0x0009d8e8, "Hn1.100": 0x0009d364, "Hn1.10A": 0x0009d3ec, "Hn1.200": 0x0009d060,
        "Hx1.0A0": 0x0007db00, "Hx1.090": 0x0007daf4, "Hx1.080": 0x0007dabc, "Hx1.070": 0x0007da88, "Hx1.060": 0x0007da88, "Hx1.040": 0x0007da90,
    ]
    private static let patchValue: [String: [UInt8]] = [
        "S1.600,S1.500,S1.400,S1.300,S1.200,S1.100,S1.000": [0x13, 0x48, 0x00, 0x47],
        "R1.400,R1.300,R1.200,R1.100,R1.000": [0x1a, 0x48, 0x00, 0x47],
        "Hr1.000": [0x10, 0x48, 0x00, 0x47],
        "Hn1.200,Hn1.10A,Hn1.100,Hn1.000,Hx1.0A0,Hx1.090,Hx1.080,Hx1.070,Hx1.060,Hx1.040": [0x12, 0x48, 0x00, 0x47],
    ]
    private static let commandByte: [String: Int] = ["Hr*,Hn*,Hx*": 0xd2, "S*": 0xd2, "R*": 0xd3]

    init(factory: FactoryInterface, iface: NetMDInterface, versionCode: String, maxSlots: Int) {
        self.factory = factory; self.iface = iface; self.versionCode = versionCode; self.maxSlots = maxSlots
    }

    /// Patches the trampoline in if it isn't already present (e.g. from a previous session or a
    /// hard-patched developer unit), then becomes usable via `execute`.
    public func activate() throws {
        guard let command = VersionStore.lookup(Self.commandByte, version: versionCode) else {
            throw NetMDError.unsupported("USB code execution is not available on firmware \(versionCode)")
        }
        // Probe code (verbatim from netmd-exploits): reads back 0 once the trampoline is active.
        // Requested generously (not via `defaultReplyLength`): before the trampoline is confirmed
        // active, the *stock* firmware is the one replying to this synthetic command, and exactly
        // how big that reply is isn't something to risk getting precisely right — requesting more
        // than the device sends is harmless (short read), requesting less is a hard USB error.
        let probe: [UInt8] = [0x01, 0x00, 0xa0, 0xe3, 0x00, 0x00, 0xcf, 0xe5, 0x1e, 0xff, 0x2f, 0xe1, 0x00]
        let reply = try rawExecute(probe, command: command, replyLength: 64)
        if reply.first != 0 {
            guard let address = VersionStore.lookup(Self.patchAddress, version: versionCode),
                  let value = VersionStore.lookup(Self.patchValue, version: versionCode) else {
                throw NetMDError.unsupported("No USB code execution patch known for firmware \(versionCode)")
            }
            // Only one patch is ever active per session in this app, so slot 0 is always free.
            let slot = 0
            try factory.patch(address: address, value: value, slot: slot, maxSlots: maxSlots)
            patchSlot = slot
        }
    }

    public func deactivate() {
        guard let slot = patchSlot else { return }
        try? factory.unpatch(slot: slot, maxSlots: maxSlots)
        patchSlot = nil
    }

    /// Runs `code` (already-assembled ARM or THUMB machine code) on the device and returns
    /// whatever it wrote back to the same buffer. `replyLength` defaults to netmd-exploits' own
    /// convention of echoing back the whole query (`query.byteLength + 1`), where the query is
    /// `00 18<command> ff <code>` — 4 fixed bytes plus `code`.
    public func execute(_ code: [UInt8], replyLength: Int? = nil) throws -> [UInt8] {
        guard let command = VersionStore.lookup(Self.commandByte, version: versionCode) else {
            throw NetMDError.unsupported("USB code execution is not available on firmware \(versionCode)")
        }
        return try rawExecute(code, command: command, replyLength: replyLength ?? Self.defaultReplyLength(for: code.count))
    }

    /// `query.byteLength + 1` for a query of `00 18<command> ff <code>` (4 fixed bytes + code).
    /// A buffer requested smaller than what the device actually sends back is a hard USB error
    /// (libusb reports `LIBUSB_ERROR_OVERFLOW`) — unlike WebUSB, which silently truncates — so
    /// this must match the device's real reply size, not just be "big enough".
    private static func defaultReplyLength(for codeCount: Int) -> Int { codeCount + 4 + 1 }

    private func rawExecute(_ code: [UInt8], command: Int, replyLength: Int) throws -> [UInt8] {
        let query = try Query.format("00 18%b ff %*", .b(command), .bytes(code))
        try iface.transport.sendCommand(query)
        // The reply is read with a fixed length (see readReplyFixedLength) because injected code
        // doesn't go through the firmware's normal "announce reply length" step.
        let data = try iface.transport.readReplyFixedLength(replyLength)
        let res = try Query.scan(data, "08 18%? ff %*")
        return res[0].bytesValue
    }
}
