import Foundation

/// Decodes raw ATRAC containers (as `HomebrewRipper` produces for SP tracks) to a playable WAV,
/// via the system's ffmpeg if one is installed — macOS has no native AEA/ATRAC1 support, so
/// without this an SP rip is correct but unplayable by anything but specialist tools.
public enum ATRACDecoding {
    public static var isAvailable: Bool { AudioImporter.locateTool("ffmpeg") != nil }

    /// Decodes an AEA file's bytes to 16-bit PCM WAV. Returns `nil` if ffmpeg isn't installed;
    /// throws if ffmpeg is present but fails to decode (e.g. a build without ATRAC1 support).
    public static func decodeAEAToWAV(_ aeaData: [UInt8]) throws -> [UInt8]? {
        guard let ffmpeg = AudioImporter.locateTool("ffmpeg") else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MDKit-decode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let inURL = dir.appendingPathComponent("in.aea")
        let outURL = dir.appendingPathComponent("out.wav")
        try Data(aeaData).write(to: inURL)

        let proc = Process()
        proc.executableURL = ffmpeg
        proc.arguments = ["-y", "-v", "error", "-i", inURL.path, "-f", "wav", outURL.path]
        let err = Pipe()
        proc.standardError = err
        proc.standardOutput = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0, let data = try? Data(contentsOf: outURL) else {
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw AudioImportError.encoderFailed(msg.isEmpty ? "ffmpeg exit status \(proc.terminationStatus)" : msg)
        }
        return [UInt8](data)
    }
}
