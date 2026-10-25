import XCTest
@testable import NetMDKit

/// Runs against a real NetMD deck holding a BLANK, writable disc. Skipped unless MDKIT_HARDWARE=1.
///
///   MDKIT_HARDWARE=1 ATRACDENC_PATH=build/atracdenc swift test --filter HardwareTests
///
/// Quit MDKit first: only one program can hold the deck's USB interface. The test refuses to run on a disc
/// that already has tracks, and deletes only the tracks it recorded.
final class HardwareTests: XCTestCase {
    private func tone(seconds: Int) -> [UInt8] {
        var pcm = [UInt8](); pcm.reserveCapacity(seconds * 44100 * 4)
        for i in 0..<(seconds * 44100) {
            let s = Int16(10_000 * sin(2 * Double.pi * 440 * Double(i) / 44100))
            let b = withUnsafeBytes(of: s.littleEndian, Array.init)
            pcm += b; pcm += b
        }
        return pcm
    }

    private func prepared(_ name: String, seconds: Int, mode: RecordingMode) throws -> PreparedTrack {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mdkit-hw-\(name).wav")
        try AudioImporter.wavFile(fromPCM16LE: tone(seconds: seconds)).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try AudioImporter.prepare(url: url, title: name, mode: mode)
    }

    func testUploadRipCancelRoundTrip() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MDKIT_HARDWARE"] == "1", "set MDKIT_HARDWARE=1 to run against a deck")
        let device = try XCTUnwrap(NetMDTransport.attachedDevices().first, "no NetMD deck attached")
        let iface = NetMDInterface(transport: try NetMDTransport(device: device))
        defer { iface.transport.close() }

        let before = try iface.listContent()
        XCTAssertTrue(before.writable, "disc is not writable")
        try XCTSkipUnless(before.trackCount == 0, "disc is not blank; refusing to touch it")
        defer { try? iface.deleteTracks(Array(0..<((try? iface.getTrackCount()) ?? 0))) }

        // Upload: SP (PCM) and LP2 (encoded by atracdenc, the path whose stderr handling changed).
        let sp = try prepared("hw-sp", seconds: 20, mode: .sp)
        let lp2 = try prepared("hw-lp2", seconds: 20, mode: .lp2)
        XCTAssertEqual(try iface.upload(sp), 0)
        XCTAssertEqual(try iface.upload(lp2), 1)
        let disc = try iface.listContent()
        XCTAssertEqual(disc.trackCount, 2)
        XCTAssertEqual(disc.allTracks.map(\.title), ["hw-sp", "hw-lp2"])
        for t in disc.allTracks { XCTAssertEqual(t.seconds, 20, accuracy: 1.5, "\(t.title) duration") }

        // Rip both back.
        let ripper = HomebrewRipper(iface)
        try ripper.connect()
        defer { ripper.disconnect() }

        let spRip = try ripper.downloadTrack(0)
        XCTAssertEqual(spRip.fileExtension, "aea")
        let wav = try XCTUnwrap(try ATRACDecoding.decodeAEAToWAV(spRip.data), "ffmpeg should decode the ripped AEA")
        XCTAssertGreaterThan(wav.count, 20 * 44100 * 4 * 9 / 10, "decoded SP rip is shorter than ~18 s")

        let lpRip = try ripper.downloadTrack(1)
        XCTAssertEqual(lpRip.fileExtension, "wav")
        XCTAssertGreaterThan(lpRip.data.count, 100_000)

        // Cancel partway through a rip, then make sure a fresh rip still works.
        var reads = 0
        XCTAssertThrowsError(try ripper.downloadTrack(0, progress: { p in if p.action == "READ" { reads = p.read } },
                                                      isCancelled: { reads >= 20 })) { e in
            guard case NetMDError.cancelled = e else { return XCTFail("expected cancelled, got \(e)") }
        }
        let again = try ripper.downloadTrack(0)
        XCTAssertEqual(again.data.count, spRip.data.count, "rip after a cancel differs in size from the first rip")
    }

    /// Interactive: needs a person to pull the USB cable mid-rip. LEAVES THE DECK HUNG (see AGENTS.md): it only
    /// recovers after its batteries or power adapter are removed, and the test then fails at the replug step. Also set MDKIT_UNPLUG_DIR to a writable directory;
    /// the test writes `unplug-now` there once the rip is under way and `result.txt` at the end.
    func testUnplugDuringRip() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["MDKIT_HARDWARE"] == "1" && env["MDKIT_UNPLUG_DIR"] != nil, "interactive; set MDKIT_HARDWARE=1 and MDKIT_UNPLUG_DIR")
        let dir = URL(fileURLWithPath: env["MDKIT_UNPLUG_DIR"]!)
        var log = [String]()
        func note(_ s: String) { log.append(s); try? log.joined(separator: "\n").write(to: dir.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8) }

        let device = try XCTUnwrap(NetMDTransport.attachedDevices().first, "no NetMD deck attached")
        var iface = NetMDInterface(transport: try NetMDTransport(device: device))
        let before = try iface.listContent()
        try XCTSkipUnless(before.trackCount == 0, "disc is not blank; refusing to touch it")

        try iface.upload(try prepared("hw-unplug", seconds: 90, mode: .sp))
        let ripper = HomebrewRipper(iface)
        try ripper.connect()
        note("rip starting")

        var reads = 0, signalled = false
        let started = Date()
        var failedAt: Date?
        do {
            _ = try ripper.downloadTrack(0, progress: { p in
                if p.action == "READ" { reads = p.read }
                if reads >= 30, !signalled {
                    signalled = true
                    try? "go".write(to: dir.appendingPathComponent("unplug-now"), atomically: true, encoding: .utf8)
                }
            })
            note("RIP COMPLETED without the cable being pulled (\(Int(Date().timeIntervalSince(started))) s)")
        } catch {
            failedAt = Date()
            note("rip failed after \(reads) sectors, \(Int(Date().timeIntervalSince(started))) s in: \(error)")
        }
        ripper.disconnect()
        iface.transport.close()
        guard failedAt != nil else { return XCTFail("cable was not pulled in time") }

        // Wait for the deck to come back, then see whether it is usable and clean up.
        note("waiting for the deck to be plugged back in")
        var back: AttachedDevice?
        for _ in 0..<180 { if let d = NetMDTransport.attachedDevices().first { back = d; break }; Thread.sleep(forTimeInterval: 1) }
        let d2 = try XCTUnwrap(back, "deck never reappeared")
        Thread.sleep(forTimeInterval: 5)
        iface = NetMDInterface(transport: try NetMDTransport(device: d2))
        defer { iface.transport.close() }
        let after = try iface.listContent()
        note("deck back; disc has \(after.trackCount) track(s)")
        let r2 = HomebrewRipper(iface)
        try r2.connect()
        let rip = try r2.downloadTrack(0, progress: nil, isCancelled: { false })
        note("fresh rip after replug OK: \(rip.data.count) bytes")
        r2.disconnect()
        try iface.deleteTracks(Array(0..<(try iface.getTrackCount())))
        note("cleaned up; disc has \(try iface.getTrackCount()) track(s)")
    }

    /// Read-only probe of a deck's state: can it answer a plain status query?
    func testProbe() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MDKIT_PROBE"] == "1", "set MDKIT_PROBE=1")
        let device = try XCTUnwrap(NetMDTransport.attachedDevices().first, "no NetMD deck attached")
        let iface = NetMDInterface(transport: try NetMDTransport(device: device))
        defer { iface.transport.close() }
        for attempt in 1...3 {
            do {
                print("PROBE attempt \(attempt): status \(try iface.getStatus())")
                // Optional: remove leftovers from interrupted hardware tests (only tracks titled "hw-*").
                if ProcessInfo.processInfo.environment["MDKIT_CLEANUP"] == "1" {
                    let mine = try iface.listContent().allTracks.filter { $0.title.hasPrefix("hw-") }.map(\.index)
                    try iface.deleteTracks(mine)
                    print("PROBE removed \(mine.count) test track(s); disc now has \(try iface.getTrackCount())")
                }
                return
            }
            catch { print("PROBE attempt \(attempt): \(error)") }
            Thread.sleep(forTimeInterval: 3)
        }
        XCTFail("deck does not answer status queries")
    }
}
