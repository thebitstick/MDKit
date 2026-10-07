import Foundation

/// The one piece of "homebrew mode ripping" that needs an ARM/THUMB assembler at runtime rather
/// than a fixed data table: the tiny relocatable stub that, each time it's run via
/// `USBCodeExecution`, points the firmware's own DRAM-read routine at a given sector/offset and
/// copies the result into the USB reply buffer. Its *logic* is always the same; only the
/// addresses of firmware functions it calls (`read_atrac_dram`, `g_DiscStateStruct`) and one
/// struct offset change per exact firmware version, so it has to be assembled per-version rather
/// than shipped as one fixed blob.
///
/// Keystone (linked as `CKeystone`) does the actual ARM encoding; this type just builds the
/// source text per firmware version and handles netmd-exploits' self-referential sizing trick
/// (see `assembleNoRamRead`).
public enum FirmwareAssembler {
    /// Per-exact-firmware-version addresses the no-RAM recovery stub needs. Copied verbatim from
    /// netmd-exploits' `CORE_MACROS.fw_compat_bridge` / `CachedSectorNoRamControlDownload`.
    struct NoRamAddresses { var readAtracDram: Int; var discStateStruct: Int; var discStructOffset: Int }

    static let noRamAddresses: [String: NoRamAddresses] = [
        "S1.600": .init(readAtracDram: 0x000781fd, discStateStruct: 0x020001e8, discStructOffset: 0x24),
        "S1.500": .init(readAtracDram: 0x00077805, discStateStruct: 0x020001e8, discStructOffset: 0x24),
        "S1.400": .init(readAtracDram: 0x00077131, discStateStruct: 0x020001e8, discStructOffset: 0x24),
        "S1.300": .init(readAtracDram: 0x00073a71, discStateStruct: 0x020001d8, discStructOffset: 0x24),
        "S1.200": .init(readAtracDram: 0x000723bd, discStateStruct: 0x020001cc, discStructOffset: 0x24),
        "S1.100": .init(readAtracDram: 0x00071a35, discStateStruct: 0x020001cc, discStructOffset: 0x24),
        "S1.000": .init(readAtracDram: 0x00078365, discStateStruct: 0x020001e8, discStructOffset: 0x24),
        "R1.000": .init(readAtracDram: 0x0005d37d, discStateStruct: 0x02000b34, discStructOffset: 0x1c),
        "R1.100": .init(readAtracDram: 0x0005dc65, discStateStruct: 0x02000b38, discStructOffset: 0x1c),
        "R1.200": .init(readAtracDram: 0x0005e9fd, discStateStruct: 0x02000b34, discStructOffset: 0x18),
        "R1.300": .init(readAtracDram: 0x0005ed51, discStateStruct: 0x02000b34, discStructOffset: 0x18),
        "R1.400": .init(readAtracDram: 0x0005edf1, discStateStruct: 0x02000b38, discStructOffset: 0x18),
    ]

    /// ARM assembly source for the relocatable stub (netmd-exploits'
    /// `CachedSectorNoRamControlDownload`'s "code" template, with its macros — `@fw_compat_bridge`
    /// resolving to nothing here, `@blxar` expanded inline, `@bridge word` expanded to a labeled
    /// `.word` — unrolled by hand and `$name`/`%cLength` substituted with concrete values instead
    /// of the original's own tiny expression language, since Keystone just wants plain ARM.
    ///
    /// `cLength` is the assembled length of this *same* template (including the three trailing
    /// placeholder words) — a self-referential size the firmware needs to adjust a struct field
    /// by, to account for this stub's own footprint. `assembleNoRamRead` resolves it by assembling
    /// twice, exactly as netmd-exploits does.
    private static func source(cLength: Int, _ a: NoRamAddresses) -> String {
        """
        push {r3, r4, lr}
        ldr r0, disc_state_struct
        ldr r1, length
        add r1, r1, #\(cLength + 4)
        str r1, [r0, #\(a.discStructOffset)]
        str r1, [r0, #\(a.discStructOffset - 4)]
        ldr r0, sector
        ldr r1, subsector_start
        adr r2, after_words
        ldr r3, length
        add r4, pc, #0xc
        mov lr, r4
        ldr r4, [pc]
        bx r4
        .word \(a.readAtracDram)
        pop {r3, r4, lr}
        bx lr
        disc_state_struct: .word \(a.discStateStruct)
        sector: .word 0
        subsector_start: .word 0
        length: .word 0
        after_words:
        """
    }

    static func assemble(_ text: String, thumb: Bool) throws -> [UInt8] {
        try Keystone.assemble(text, mode: thumb ? .thumb : .arm)
    }

    /// A no-RAM-recovery stub assembled once for a given firmware version and reused for every
    /// sector/chunk read (re-invoking Keystone per USB round-trip would be needlessly slow).
    public struct NoRamTemplate {
        /// The template body (fixed instructions only — the three trailing placeholder words
        /// assembly produced them with have already been stripped).
        let body: [UInt8]
        /// Netmd-exploits' `codeLength`: the *full* assembled length, body + the three trailing
        /// words, i.e. `body.count + 12`. The device's reply convention is keyed off this: for a
        /// requested payload of `length` bytes, the reply is `length + codeLength + 4` bytes long,
        /// of which the first `codeLength` are not data (handshake remnants), leaving
        /// `length + 4` actual bytes at the end — both the +4 and the exact reply-length
        /// convention are device behavior observed by netmd-exploits, not derived from the stub's
        /// logic, so they're reproduced as-is rather than "cleaned up".
        public let codeLength: Int

        public func makeCode(sector: Int, subsectorStart: Int, length: Int) -> [UInt8] {
            body + leWord(sector) + leWord(subsectorStart) + leWord(length)
        }
    }

    private static var templateCache: [String: NoRamTemplate] = [:]
    private static let templateCacheLock = NSLock()

    /// Compiles (and caches) the no-RAM recovery stub for `versionCode`.
    public static func noRamTemplate(for versionCode: String) throws -> NoRamTemplate {
        templateCacheLock.lock(); defer { templateCacheLock.unlock() }
        if let cached = templateCache[versionCode] { return cached }

        guard let a = noRamAddresses[versionCode] else {
            throw NetMDError.unsupported("No-RAM ATRAC recovery isn't known for firmware \(versionCode)")
        }
        // Pass 1: assemble with cLength=0 purely to measure the template's own length (body +
        // the 12 trailing placeholder bytes for sector/subsectorStart/length).
        let probeLength = try assemble(source(cLength: 0, a), thumb: false).count
        // Pass 2: re-assemble with the real self-referential size. Changing that one immediate
        // doesn't change the instruction's encoded size (both 0 and probeLength fit the same ARM
        // rotated-immediate form here), so the result is the same length as pass 1.
        let full = try assemble(source(cLength: probeLength, a), thumb: false)
        guard full.count == probeLength else {
            throw NetMDError.protocolError("Firmware stub length changed between assembly passes (\(probeLength) vs \(full.count))")
        }
        let template = NoRamTemplate(body: Array(full.dropLast(12)), codeLength: probeLength)
        templateCache[versionCode] = template
        return template
    }

    // MARK: - Control-transfer backend (fast path)
    //
    // Unlike the no-RAM stub, this installs *resident* code: a small handler, copied once into a
    // fixed RAM address, that the firmware's own USB-reply routine gets redirected into. Once
    // installed, reading a sector is a single standard `readReply(2352)` — no per-chunk
    // round-trips through USBCodeExecution — which is what makes it fast enough to keep up with
    // the drive's own DRAM cache (the no-RAM backend's slowness is the likely cause of the data
    // loss/speed-up artifacts seen with it).
    //
    // Ported from netmd-exploits' `CachedSectorControlDownload`, S*-only (upstream notes Type-R
    // decks become unstable with this method, so it never enables it there either — the no-RAM
    // backend remains the fallback for R* firmware). The installer copies the resident payload,
    // zero-initializes it, and applies both firmware redirect patches all within one injected
    // run (see `installerSource`) — deliberately NOT split into separate host-side steps, despite
    // `FactoryInterface.patch` being available and already verified elsewhere: the target function
    // is called continuously by the firmware's own background USB polling, so anything less than
    // atomic installation leaves a window where a half-applied patch can hang the deck.
    struct ControlAddresses {
        var residentCode, enabledFlag, sectorToRead, sectorBuffer: Int
        var discStateStruct, discStructOffset, gUsbBuff, usbDoResponse: Int
        var usbReadStandardResponse, usbReadStandardResponseNext: Int
    }

    static let controlAddresses: [String: ControlAddresses] = [
        "S1.600": .init(residentCode: 0x02005f00, enabledFlag: 0x02005500, sectorToRead: 0x02005600, sectorBuffer: 0x02006f00,
                        discStateStruct: 0x020001e8, discStructOffset: 0x24, gUsbBuff: 0x02001170, usbDoResponse: 0x00077a3d,
                        usbReadStandardResponse: 0x0000de4c, usbReadStandardResponseNext: 0x0000de50),
        "S1.500": .init(residentCode: 0x02005f00, enabledFlag: 0x02005500, sectorToRead: 0x02005600, sectorBuffer: 0x02006f00,
                        discStateStruct: 0x020001e8, discStructOffset: 0x24, gUsbBuff: 0x02001158, usbDoResponse: 0x00077045,
                        usbReadStandardResponse: 0x0000dcec, usbReadStandardResponseNext: 0x0000dcf0),
        "S1.400": .init(residentCode: 0x02005f00, enabledFlag: 0x02005500, sectorToRead: 0x02005600, sectorBuffer: 0x02006f00,
                        discStateStruct: 0x020001e8, discStructOffset: 0x24, gUsbBuff: 0x0200113c, usbDoResponse: 0x00076971,
                        usbReadStandardResponse: 0x0000dca4, usbReadStandardResponseNext: 0x0000dca8),
        "S1.300": .init(residentCode: 0x02005f00, enabledFlag: 0x02005500, sectorToRead: 0x02005600, sectorBuffer: 0x02006f00,
                        discStateStruct: 0x020001d8, discStructOffset: 0x24, gUsbBuff: 0x0200102c, usbDoResponse: 0x000732c1,
                        usbReadStandardResponse: 0x0000d25c, usbReadStandardResponseNext: 0x0000d260),
        "S1.200": .init(residentCode: 0x02005f00, enabledFlag: 0x02005500, sectorToRead: 0x02005600, sectorBuffer: 0x02006f00,
                        discStateStruct: 0x020001cc, discStructOffset: 0x24, gUsbBuff: 0x02001018, usbDoResponse: 0x00071ca9,
                        usbReadStandardResponse: 0x0000cfe8, usbReadStandardResponseNext: 0x0000cfec),
        "S1.100": .init(residentCode: 0x02005f00, enabledFlag: 0x02005500, sectorToRead: 0x02005600, sectorBuffer: 0x02006f00,
                        discStateStruct: 0x020001cc, discStructOffset: 0x24, gUsbBuff: 0x02001014, usbDoResponse: 0x00071321,
                        usbReadStandardResponse: 0x0000cf5c, usbReadStandardResponseNext: 0x0000cf60),
        "S1.000": .init(residentCode: 0x02005f00, enabledFlag: 0x02005500, sectorToRead: 0x02005600, sectorBuffer: 0x02006f00,
                        discStateStruct: 0x020001e8, discStructOffset: 0x24, gUsbBuff: 0x0200117c, usbDoResponse: 0x00077ba5,
                        usbReadStandardResponse: 0x0000df34, usbReadStandardResponseNext: 0x0000df38),
    ]

    /// The resident handler, copied once to `residentCode`. Each time the firmware's USB-reply
    /// routine is redirected here (via the two installed patches): if `enabledFlag` is zero it
    /// falls through to the original standard-response behavior unchanged; otherwise it reads
    /// 2352 bytes of the current ATRAC sector into `sectorBuffer`, advances the sector counter,
    /// and replies with that instead.
    private static func residentPayloadSource(_ a: ControlAddresses, readAtracDram: Int) -> String {
        """
        push {r3, r4, r5, r6, r7}
        ldr r0, enabled_flag
        ldr r0, [r0]
        cmp r0, #0
        ldr r0, disc_state_struct
        ldr r1, [r0, #\(a.discStructOffset)]
        ldr r0, g_usb_buff
        beq handle_unchanged
        ldr r0, sector_to_read
        ldr r0, [r0]
        push {r0}
        mov r1, #0
        ldr r2, sector_buffer
        mov r3, #2352
        mov r7, lr
        add r4, pc, #0xc
        mov lr, r4
        ldr r4, [pc]
        bx r4
        .word \(readAtracDram)
        pop {r0}
        add r0, r0, #1
        ldr r1, sector_to_read
        str r0, [r1]
        ldr r0, sector_buffer
        mov r1, #2352
        mov lr, r7
        handle_unchanged:
        pop {r3, r4, r5, r6, r7}
        ldr r2, [pc]
        bx r2
        .word \(a.usbDoResponse)
        disc_state_struct: .word \(a.discStateStruct)
        g_usb_buff: .word \(a.gUsbBuff)
        sector_buffer: .word \(a.sectorBuffer)
        sector_to_read: .word \(a.sectorToRead)
        enabled_flag: .word \(a.enabledFlag)
        """
    }

    /// Patch-table RAM structure every factory-mode deck exposes (same one `FactoryInterface.patch`
    /// writes to from the host) — needed here too because, unlike every other patch this app
    /// applies, these two *must* land atomically from within one injected run. `usbReadStandardResponse`
    /// is called continuously by the firmware's own background USB polling, independent of anything
    /// the host does; applying the two patches as two separate host-side round-trips (as this file
    /// briefly did) leaves a window where the first patch — a jump instruction — is live but its
    /// target (the second patch) hasn't been written yet, so the very next background poll jumps to
    /// garbage and hangs the deck. Doing the whole install (copy the payload, zero-initialize its
    /// enable flag, apply both patches) as one injected program closes that window, because the
    /// firmware's own main loop is paused for the whole call — nothing else can run USB polling
    /// while we're executing. This is netmd-exploits' own `@patch` macro, inlined as a subroutine.
    private static func patchSubroutineSource(maxSlots: Int) -> String {
        let base = PatchPeripheralBase.netmd.rawValue
        let control = base + maxSlots * 0x10
        return """
        do_patch:
        ldr r0, patch_control
        mov r1, #5
        strb r1, [r0]
        mov r1, #12
        strb r1, [r0]
        ldr r0, patch_base
        lsl r5, r5, #4
        add r0, r0, r5
        ldr r1, [r0]
        and r1, r1, #0xfe
        str r1, [r0]
        ldr r1, [r0]
        and r1, r1, #0xfd
        str r1, [r0], #4
        str r3, [r0], #4
        str r4, [r0]
        sub r0, r0, #8
        ldr r1, [r0]
        orr r1, r1, #1
        str r1, [r0]
        ldr r0, patch_control
        mov r1, #5
        strb r1, [r0]
        mov r1, #9
        strb r1, [r0]
        bx lr
        patch_control: .word \(control)
        patch_base: .word \(base)
        """
    }

    /// The full atomic installer: copies the resident payload to `residentCode` (terminated by the
    /// `0xBADC0DE0` sentinel, chosen — verbatim from upstream — to be vanishingly unlikely to occur
    /// naturally in this specific payload), zeroes the enable flag and sector counter so the handler
    /// starts safely disabled the instant it goes live, then applies both redirect patches via the
    /// subroutine above before returning to the firmware exactly where it left off.
    private static func installerSource(_ a: ControlAddresses, readAtracDram: Int, maxSlots: Int) -> String {
        """
        ldr r0, dest
        adr r1, payload
        ldr r3, end_marker
        copy_loop:
        ldr r2, [r1], #4
        cmp r2, r3
        beq copy_done
        str r2, [r0], #4
        b copy_loop
        copy_done:
        mov r7, lr
        ldr r1, enabled_flag_addr
        mov r0, #0
        str r0, [r1]
        ldr r1, sector_to_read_addr
        mov r0, #0
        str r0, [r1]
        mov r5, #1
        ldr r3, patch1_addr
        ldr r4, patch1_val
        bl do_patch
        mov r5, #2
        ldr r3, patch2_addr
        ldr r4, patch2_val
        bl do_patch
        bx r7
        \(patchSubroutineSource(maxSlots: maxSlots))
        dest: .word \(a.residentCode)
        end_marker: .word 0xBADC0DE0
        enabled_flag_addr: .word \(a.enabledFlag)
        sector_to_read_addr: .word \(a.sectorToRead)
        patch1_addr: .word \(a.usbReadStandardResponse)
        patch1_val: .word 0x47104a00
        patch2_addr: .word \(a.usbReadStandardResponseNext)
        patch2_val: .word \(a.residentCode)
        payload:
        \(residentPayloadSource(a, readAtracDram: readAtracDram))
        .word 0xBADC0DE0
        """
    }

    public static func assembleControlInstaller(for versionCode: String, maxSlots: Int = 8) throws -> [UInt8] {
        guard let a = controlAddresses[versionCode] else {
            throw NetMDError.unsupported("Control-transfer ATRAC recovery isn't known for firmware \(versionCode)")
        }
        guard let readAtracDram = noRamAddresses[versionCode]?.readAtracDram else {
            throw NetMDError.unsupported("Missing read_atrac_dram address for firmware \(versionCode)")
        }
        return try assemble(installerSource(a, readAtracDram: readAtracDram, maxSlots: maxSlots), thumb: false)
    }
}
