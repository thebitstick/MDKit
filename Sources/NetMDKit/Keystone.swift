import Foundation
import CKeystone

/// Thin Swift wrapper over Keystone (BSD-3, github.com/keystone-engine/keystone), linked
/// statically. This is the ARM/THUMB assembler `FirmwareAssembler` uses to turn the small,
/// per-firmware-version sector-recovery stub into machine code at runtime.
enum Keystone {
    enum Mode { case arm, thumb }

    /// Assembles `source` at load address `address` (usually 0 — these stubs are PC-relative or
    /// relocated by the caller) and returns the resulting machine code.
    static func assemble(_ source: String, mode: Mode, address: UInt64 = 0) throws -> [UInt8] {
        var engine: OpaquePointer?
        let ksMode: Int32 = mode == .thumb ? Int32(KS_MODE_THUMB.rawValue) : Int32(KS_MODE_ARM.rawValue)
        let openResult = ks_open(KS_ARCH_ARM, ksMode, &engine)
        guard openResult == KS_ERR_OK, let engine else {
            throw NetMDError.unsupported("Keystone failed to initialize (\(String(cString: ks_strerror(openResult))))")
        }
        defer { ks_close(engine) }

        var encoding: UnsafeMutablePointer<UInt8>?
        var encodingSize: Int = 0
        var statementCount: Int = 0
        let rc = source.withCString { cstr in
            ks_asm(engine, cstr, address, &encoding, &encodingSize, &statementCount)
        }
        guard rc == 0, let encoding else {
            let err = ks_errno(engine)
            throw NetMDError.unsupported("Keystone assembly failed (\(String(cString: ks_strerror(err)))) in:\n\(source)")
        }
        defer { ks_free(encoding) }
        return Array(UnsafeBufferPointer(start: encoding, count: encodingSize))
    }
}
