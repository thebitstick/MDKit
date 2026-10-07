import Foundation

/// AEA (Sony's raw-ATRAC1 container, used for SP tracks) and the ATRAC3-flavoured WAV header
/// (used for LP2/LP4), ported from netmd-js's `createAeaHeader`/`createWavHeader`. Needed to
/// write out what "homebrew mode ripping" recovers as a file something else (foobar2000, the
/// SonicStage/OpenMG tools, ffmpeg's `libavcodec/atrac1dec`) can open.
public enum AEAWAV {
    private static func le32(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)] }
    private static func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)] }

    /// `channels`: 1 (mono) or 2 (stereo). `soundGroups`: number of 212-byte ATRAC1 frames.
    public static func aeaHeader(title: String, channels: Int, soundGroups: Int) -> [UInt8] {
        var h = [UInt8]()
        h += le32(2048) // Magic
        let name = Array(Titles.encodeSJIS(title).prefix(256))
        h += name + [UInt8](repeating: 0, count: 256 - name.count)
        h += le32(soundGroups)
        h += [UInt8(channels), 0]
        h += [UInt8](repeating: 0, count: 8 * 4) // flags[0..7]
        h += le32(0)
        h += le32(0) // encrypted
        h += le32(0) // groupStart
        h += [UInt8](repeating: 0, count: 2048 - h.count)
        return h
    }

    public static func wavHeader(format: RecoveredFormat, byteCount: Int) -> [UInt8] {
        let bytesPerFrame = format == .lp2 ? 192 : 96
        let jointStereo = format == .lp2 ? 0 : 1
        let bytesPerSecond = bytesPerFrame * 44100 / 512
        var h = [UInt8]()
        h += Array("RIFF".utf8)
        h += le32(byteCount + 60)
        h += Array("WAVEfmt ".utf8)
        h += le32(32)
        h += le16(0x270) // ATRAC3
        h += le16(2)
        h += le32(44100)
        h += le32(bytesPerSecond)
        h += le16(bytesPerFrame * 2)
        h += [0, 0]
        h += le16(14)
        h += le16(1)
        h += le32(bytesPerFrame)
        h += le16(jointStereo)
        h += le16(jointStereo)
        h += le16(1)
        h += le16(0)
        h += Array("data".utf8)
        h += le32(byteCount)
        return h
    }
}
