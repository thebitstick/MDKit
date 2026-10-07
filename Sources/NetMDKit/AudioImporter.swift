import Foundation
import AVFoundation

public struct AudioMetadata {
    public var title: String
    public var artist: String
    public var album: String
    public var duration: Double
}

public enum RecordingMode: String, CaseIterable, Identifiable {
    case sp = "SP", lp2 = "LP2", lp4 = "LP4"
    public var id: String { rawValue }

    public var wireformat: Wireformat {
        switch self { case .sp: return .pcm; case .lp2: return .lp2; case .lp4: return .lp4 }
    }
    public var atracBitrateKbps: Int { self == .lp2 ? 128 : 64 }
    /// Disc-time multiplier relative to SP.
    public var discTimeFactor: Double { switch self { case .sp: return 1; case .lp2: return 0.5; case .lp4: return 0.25 } }
}

public enum AudioImportError: LocalizedError {
    case unreadable(String)
    case encoderMissing
    case encoderFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let f): return "Could not read audio from “\(f)”."
        case .encoderMissing: return "The ATRAC3 encoder (atracdenc) was not found, so LP2/LP4 uploads are unavailable."
        case .encoderFailed(let m): return "ATRAC3 encoding failed: \(m)"
        }
    }
}

/// Decodes arbitrary audio files and (for LP modes) runs them through atracdenc.
public enum AudioImporter {
    public static func metadata(for url: URL) async -> AudioMetadata {
        let fallback = url.deletingPathExtension().lastPathComponent
        if let at3 = try? ATRAC3File.parse(Data(contentsOf: url, options: .mappedIfSafe)) {
            return AudioMetadata(title: fallback, artist: "", album: "", duration: at3.duration)
        }
        let asset = AVURLAsset(url: url)
        var title = fallback, artist = "", album = ""
        if let items = try? await asset.load(.commonMetadata) {
            func value(_ key: AVMetadataKey) async -> String? {
                guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: AVMetadataItem.identifier(forKey: key, keySpace: .common) ?? .commonIdentifierTitle).first else { return nil }
                return try? await item.load(.stringValue)
            }
            title = await value(.commonKeyTitle) ?? fallback
            artist = await value(.commonKeyArtist) ?? ""
            album = await value(.commonKeyAlbumName) ?? ""
        }
        let seconds = (try? await asset.load(.duration).seconds) ?? 0
        return AudioMetadata(title: title, artist: artist, album: album, duration: seconds.isFinite ? seconds : 0)
    }

    /// Produces upload-ready data for `url` in the requested mode.
    public static func prepare(url: URL, title: String, mode: RecordingMode,
                               encoderURL: URL? = AudioImporter.locateEncoder(),
                               isCancelled: @escaping () -> Bool = { false },
                               stage: ((String) -> Void)? = nil) throws -> PreparedTrack {
        // Already-encoded ATRAC3 files are sent as-is.
        if let at3 = try? ATRAC3File.parse(Data(contentsOf: url)) {
            return PreparedTrack(title: title, wireformat: at3.wireformat, data: at3.payload)
        }

        stage?("Decoding audio…")
        let pcm = try decodeToPCM16LE(url: url, isCancelled: isCancelled)
        if isCancelled() { throw NetMDError.cancelled }

        switch mode {
        case .sp:
            // The device expects big-endian samples.
            var be = pcm
            be.withUnsafeMutableBytes { raw in
                let p = raw.bindMemory(to: UInt8.self)
                var i = 0
                while i + 1 < p.count { p.swapAt(i, i + 1); i += 2 }
            }
            return PreparedTrack(title: title, wireformat: .pcm, data: be)

        case .lp2, .lp4:
            guard let encoderURL else { throw AudioImportError.encoderMissing }
            stage?("Encoding to ATRAC3 (\(mode.rawValue))…")
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("wmdm-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let wavURL = tmp.appendingPathComponent("in.wav"), outURL = tmp.appendingPathComponent("out.at3")
            try wavFile(fromPCM16LE: pcm).write(to: wavURL)

            let proc = Process()
            proc.executableURL = encoderURL
            proc.arguments = ["-e", "atrac3", "--bitrate", String(mode.atracBitrateKbps), "-i", wavURL.path, "-o", outURL.path]
            let err = Pipe()
            proc.standardError = err
            proc.standardOutput = FileHandle.nullDevice
            try proc.run()
            while proc.isRunning {
                if isCancelled() { proc.terminate(); throw NetMDError.cancelled }
                Thread.sleep(forTimeInterval: 0.1)
            }
            guard proc.terminationStatus == 0, let data = try? Data(contentsOf: outURL) else {
                let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                throw AudioImportError.encoderFailed(msg.isEmpty ? "exit status \(proc.terminationStatus)" : msg)
            }
            let at3 = try ATRAC3File.parse(data)
            guard at3.wireformat == mode.wireformat else {
                throw AudioImportError.encoderFailed("Encoder produced \(at3.bytesPerFrame)-byte frames, expected \(mode.wireformat.frameSize)")
            }
            return PreparedTrack(title: title, wireformat: at3.wireformat, data: at3.payload)
        }
    }

    // MARK: Decoding

    /// Interleaved stereo, 44.1 kHz, 16-bit little-endian.
    static func decodeToPCM16LE(url: URL, isCancelled: () -> Bool) throws -> [UInt8] {
        do {
            return try decodeWithAVFoundation(url: url, isCancelled: isCancelled)
        } catch let e as NetMDError {
            throw e
        } catch {
            // Formats AVFoundation can't open (Ogg, Opus, …): fall back to ffmpeg if installed.
            if let ffmpeg = locateTool("ffmpeg") { return try decodeWithFFmpeg(ffmpeg, url: url, isCancelled: isCancelled) }
            throw AudioImportError.unreadable(url.lastPathComponent)
        }
    }

    private static func decodeWithAVFoundation(url: URL, isCancelled: () -> Bool) throws -> [UInt8] {
        let asset = AVURLAsset(url: url)
        let sema = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var tracks: [AVAssetTrack] = []
        Task { tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []; sema.signal() }
        sema.wait()
        guard !tracks.isEmpty else { throw AudioImportError.unreadable(url.lastPathComponent) }

        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? AudioImportError.unreadable(url.lastPathComponent) }

        var pcm = [UInt8]()
        while let sample = out.copyNextSampleBuffer() {
            if isCancelled() { reader.cancelReading(); throw NetMDError.cancelled }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [UInt8](repeating: 0, count: length)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &chunk)
            pcm += chunk
        }
        if reader.status == .failed { throw reader.error ?? AudioImportError.unreadable(url.lastPathComponent) }
        guard !pcm.isEmpty else { throw AudioImportError.unreadable(url.lastPathComponent) }
        return pcm
    }

    private static func decodeWithFFmpeg(_ ffmpeg: URL, url: URL, isCancelled: () -> Bool) throws -> [UInt8] {
        let proc = Process()
        proc.executableURL = ffmpeg
        proc.arguments = ["-v", "error", "-i", url.path, "-vn", "-ar", "44100", "-ac", "2", "-f", "s16le", "-"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        if isCancelled() { throw NetMDError.cancelled }
        guard proc.terminationStatus == 0, !data.isEmpty else { throw AudioImportError.unreadable(url.lastPathComponent) }
        return [UInt8](data)
    }

    static func wavFile(fromPCM16LE pcm: [UInt8]) -> Data {
        func le32(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
        func le16(_ v: UInt16) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }
        var d = Data("RIFF".utf8)
        d += le32(UInt32(36 + pcm.count)); d += Data("WAVEfmt ".utf8)
        d += le32(16); d += le16(1); d += le16(2); d += le32(44100); d += le32(44100 * 4); d += le16(4); d += le16(16)
        d += Data("data".utf8); d += le32(UInt32(pcm.count)); d += pcm
        return d
    }

    // MARK: Tool lookup

    public static func locateEncoder() -> URL? {
        if let bundled = Bundle.main.url(forResource: "atracdenc", withExtension: nil) { return bundled }
        if let env = ProcessInfo.processInfo.environment["ATRACDENC_PATH"], FileManager.default.isExecutableFile(atPath: env) {
            return URL(fileURLWithPath: env)
        }
        return locateTool("atracdenc")
    }

    static func locateTool(_ name: String) -> URL? {
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/run/current-system/sw/bin"]
            + (ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? [])
        return dirs.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

/// A RIFF/WAVE file carrying ATRAC3 frames (as produced by atracdenc and Sony tools).
public struct ATRAC3File {
    public var bytesPerFrame: Int
    public var payload: [UInt8]

    public var wireformat: Wireformat {
        // `parse` only admits 192/152/96-byte frames.
        switch bytesPerFrame { case 192: return .lp2; case 152: return .l105kbps; default: return .lp4 }
    }
    public var duration: Double { Double(payload.count / max(bytesPerFrame, 1)) * 512.0 / 44100.0 }

    public static func parse(_ file: Data) throws -> ATRAC3File {
        let d = [UInt8](file.prefix(4096))
        func u16(_ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        guard d.count >= 44, d[0..<4].elementsEqual("RIFF".utf8), d[8..<16].elementsEqual("WAVEfmt ".utf8) else {
            throw AudioImportError.unreadable("not a WAV")
        }
        let tag = u16(20), channels = u16(22)
        guard tag == 0x270 || tag == 0xfffe, channels == 2, u32(24) == 44100 else { throw AudioImportError.unreadable("not ATRAC3") }
        let frame = u16(32) / 2
        guard [192, 152, 96].contains(frame) else { throw AudioImportError.unreadable("unsupported ATRAC3 frame size") }

        var off = 12
        while off + 8 <= d.count {
            let size = u32(off + 4)
            if d[off..<off + 4].elementsEqual("data".utf8) {
                let start = off + 8
                let end = min(file.count, start + size)
                return ATRAC3File(bytesPerFrame: frame, payload: [UInt8](file[file.startIndex + start..<file.startIndex + end]))
            }
            off += 8 + size + (size & 1)
        }
        throw AudioImportError.unreadable("no data chunk")
    }
}
