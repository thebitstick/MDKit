import Foundation
import CommonCrypto

/// DES / 3DES helpers (no padding) used by the NetMD secure-session protocol.
enum DES {
    enum Mode { case ecb, cbc }

    private static func crypt(_ op: Int, algorithm: Int, keyLength: Int, mode: Mode, key: [UInt8], iv: [UInt8], data: [UInt8]) -> [UInt8] {
        precondition(data.count % 8 == 0, "DES data must be a multiple of 8 bytes")
        var out = [UInt8](repeating: 0, count: data.count + 8)
        var moved = 0
        let options = mode == .ecb ? CCOptions(kCCOptionECBMode) : 0
        let status = CCCrypt(CCOperation(op), CCAlgorithm(algorithm), options,
                             key, keyLength,
                             mode == .cbc ? iv : nil,
                             data, data.count,
                             &out, out.count, &moved)
        precondition(status == kCCSuccess, "CCCrypt failed: \(status)")
        return Array(out.prefix(moved))
    }

    static func encrypt(_ data: [UInt8], key: [UInt8], mode: Mode, iv: [UInt8] = [UInt8](repeating: 0, count: 8)) -> [UInt8] {
        crypt(kCCEncrypt, algorithm: kCCAlgorithmDES, keyLength: kCCKeySizeDES, mode: mode, key: key, iv: iv, data: data)
    }

    static func decrypt(_ data: [UInt8], key: [UInt8], mode: Mode, iv: [UInt8] = [UInt8](repeating: 0, count: 8)) -> [UInt8] {
        crypt(kCCDecrypt, algorithm: kCCAlgorithmDES, keyLength: kCCKeySizeDES, mode: mode, key: key, iv: iv, data: data)
    }

    /// Two-key 3DES (K1,K2,K1) in CBC mode, like CryptoJS does with a 16-byte key.
    static func tripleEncryptCBC(_ data: [UInt8], key16: [UInt8], iv: [UInt8]) -> [UInt8] {
        let key24 = key16 + key16.prefix(8)
        return crypt(kCCEncrypt, algorithm: kCCAlgorithm3DES, keyLength: kCCKeySize3DES, mode: .cbc, key: key24, iv: iv, data: data)
    }
}

/// Session key derivation from the EKB root key and both nonces.
func retailMAC(key: [UInt8], value: [UInt8]) -> [UInt8] {
    let subkeyA = Array(key.prefix(8))
    let beginning = Array(value.prefix(value.count - 8))
    let end = Array(value.suffix(8))
    let step1 = DES.encrypt(beginning, key: subkeyA, mode: .cbc)
    let iv2 = Array(step1.suffix(8))
    let step2 = DES.tripleEncryptCBC(end, key16: key, iv: iv2)
    return Array(step2.prefix(8))
}
