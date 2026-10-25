import Foundation
import Security

/// Audio that is ready to be streamed to the recorder.
public struct PreparedTrack {
    public var title: String
    public var fullWidthTitle: String?
    public var wireformat: Wireformat
    /// Raw payload: big-endian 16-bit stereo PCM for SP, or ATRAC3 frames for LP2/LP4.
    public var data: [UInt8]

    public init(title: String, fullWidthTitle: String? = nil, wireformat: Wireformat, data: [UInt8]) {
        self.title = title; self.fullWidthTitle = fullWidthTitle; self.wireformat = wireformat; self.data = data
    }

    /// Payload zero-padded to a whole number of frames.
    var paddedSize: Int {
        let fs = wireformat.frameSize
        return data.count % fs == 0 ? data.count : data.count + (fs - data.count % fs)
    }
    var frameCount: Int { paddedSize / wireformat.frameSize }

    /// Seconds of audio this track will occupy on disc.
    public var duration: Double {
        switch wireformat {
        case .pcm: return Double(data.count) / (44100.0 * 4)
        default: return Double(data.count / wireformat.frameSize) * 512.0 / 44100.0
        }
    }
}

public struct UploadProgress {
    public var writtenBytes: Int
    public var totalBytes: Int
    public var fraction: Double { totalBytes > 0 ? Double(writtenBytes) / Double(totalBytes) : 0 }
}

extension NetMDInterface {
    private static let contentID: [UInt8] = [
        0x01, 0x0f, 0x50, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x48,
        0xa2, 0x8d, 0x3e, 0x1a, 0x3b, 0x0c, 0x44, 0xaf, 0x2f, 0xa0,
    ]
    private static let kek: [UInt8] = [0x14, 0xe3, 0x83, 0x4e, 0xe2, 0xd3, 0xcc, 0xa5]
    private static let chunkSize = 0x10000

    private func prepareDownload() throws {
        // Sending setupDownload while the unit is still busy gets it rejected: wait for idle.
        // A status query can come back malformed while the device is mid-transition (e.g. right
        // after a disc is inserted or a previous command finishes) — that's just another reason
        // to keep waiting, not a reason to abort the whole upload.
        for _ in 0..<150 {
            if let s = try? deviceStatus().state, s == .ready || s == .discBlank { break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        _ = try? sessionKeyForget()
        _ = try? leaveSecureSession()
        try acquire()
        try? disableNewTrackProtection(1) // Not supported on Sharp units.
    }

    /// Encrypts and sends one track. Returns its new track number.
    @discardableResult
    public func upload(_ track: PreparedTrack,
                       isCancelled: @escaping () -> Bool = { false },
                       progress: ((UploadProgress) -> Void)? = nil) throws -> Int {
        try prepareDownload()
        var released = false
        func cleanup() {
            guard !released else { return }
            released = true
            _ = try? sessionKeyForget()
            _ = try? leaveSecureSession()
            _ = try? release()
        }
        defer { cleanup() }

        try enterSecureSession()
        let ekb = EKB.forDevice(leafID: try leafID(), vendorId: device.vendorId, productId: device.productId)
        try sendKeyData(ekbID: ekb.id, chain: ekb.chain, depth: ekb.depth, signature: ekb.signature)

        var hostNonce = [UInt8](repeating: 0, count: 8)
        guard SecRandomCopyBytes(kSecRandomDefault, 8, &hostNonce) == errSecSuccess else { throw NetMDError.protocolError("RNG failure") }
        let devNonce = try sessionKeyExchange(hostNonce: hostNonce)
        let sessionKey = retailMAC(key: ekb.rootKey, value: hostNonce + devNonce)

        try setupDownload(contentID: Self.contentID, kek: Self.kek, sessionKey: sessionKey)

        // Per-track data key: random raw key, transmitted wrapped under the KEK.
        var rawKey = [UInt8](repeating: 0, count: 8)
        guard SecRandomCopyBytes(kSecRandomDefault, 8, &rawKey) == errSecSuccess else { throw NetMDError.protocolError("RNG failure") }
        let wrappedKey = DES.decrypt(rawKey, key: Self.kek, mode: .ecb)

        var payload = track.data
        payload += [UInt8](repeating: 0, count: track.paddedSize - payload.count)
        var offset = 0
        var iv = [UInt8](repeating: 0, count: 8)
        var packetIndex = 0

        let (num, _, _) = try sendTrack(
            wireformat: track.wireformat, discFormat: track.wireformat.discFormat,
            frames: track.frameCount, packetSize: payload.count,
            packets: {
                if isCancelled() { throw NetMDError.cancelled }
                guard offset < payload.count else { return nil }
                let size = min(packetIndex == 0 ? Self.chunkSize - 24 : Self.chunkSize, payload.count - offset)
                let plain = Array(payload[offset..<offset + size])
                let cipher = DES.encrypt(plain, key: rawKey, mode: .cbc, iv: iv)
                let packet = EncryptedPacket(key: wrappedKey, iv: iv, data: cipher)
                iv = Array(cipher.suffix(8))
                offset += size
                packetIndex += 1
                return packet
            },
            sessionKey: sessionKey,
            progress: { written, total in progress?(UploadProgress(writtenBytes: written, totalBytes: total)) })

        try setTrackTitle(num, title: track.title)
        if let full = track.fullWidthTitle, !full.isEmpty { try setTrackTitle(num, title: full, wide: true) }
        try commitTrack(num, sessionKey: sessionKey)
        return num
    }
}
