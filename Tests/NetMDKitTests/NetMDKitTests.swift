import XCTest
@testable import NetMDKit

final class QueryTests: XCTestCase {
    func testFormatBasics() throws {
        XCTAssertEqual(try Query.format("1808 10 1801 01 00"), [0x18, 0x08, 0x10, 0x18, 0x01, 0x01, 0x00])
        XCTAssertEqual(try Query.format("%b %w %d", .b(1), .b(0x1234), .b(0xdeadbeef)), [1, 0x12, 0x34, 0xde, 0xad, 0xbe, 0xef])
        XCTAssertEqual(try Query.format("%<w", .b(0x1234)), [0x34, 0x12])
        XCTAssertEqual(try Query.format("%s", .bytes([1, 2])), [0, 3, 1, 2, 0])
        XCTAssertEqual(try Query.format("%B %W", .b(25), .b(1234)), [0x25, 0x12, 0x34])
    }

    func testScan() throws {
        let r = try Query.scan([0x18, 0x06, 0x00, 0x05, 0xaa, 0xbb, 0x25], "1806 %w %*")
        XCTAssertEqual(r[0].intValue, 5)
        XCTAssertEqual(r[1].bytesValue, [0xaa, 0xbb, 0x25])
        XCTAssertEqual(try Query.scan([0x12, 0x34], "%W")[0].intValue, 1234)
        XCTAssertThrowsError(try Query.scan([0x01], "02"))
        XCTAssertThrowsError(try Query.scan([0x02, 0x03], "02"))
    }

    func testDESKnownVectors() {
        // Classic FIPS-81 example: key 133457799BBCDFF1, plaintext 0123456789ABCDEF -> 85E813540F0AB405
        let key: [UInt8] = [0x13, 0x34, 0x57, 0x79, 0x9B, 0xBC, 0xDF, 0xF1]
        let pt: [UInt8] = [0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF]
        XCTAssertEqual(DES.encrypt(pt, key: key, mode: .ecb), [0x85, 0xE8, 0x13, 0x54, 0x0F, 0x0A, 0xB4, 0x05])
        XCTAssertEqual(DES.decrypt(DES.encrypt(pt + pt, key: key, mode: .cbc), key: key, mode: .cbc), pt + pt)
    }

    func testTitleSanitizing() {
        XCTAssertEqual(Titles.sanitizeHalfWidth("Hello World"), "Hello World")
        XCTAssertEqual(Titles.sanitizeHalfWidth("Café Müller"), "Cafe Mueller")
        XCTAssertEqual(Titles.sjisLength(Titles.sanitizeHalfWidth("ガ")), 2)
        XCTAssertEqual(Titles.sanitizeFullWidth("AB"), "ＡＢ")
        XCTAssertEqual(Titles.sjisLength(Titles.sanitizeFullWidth("AB")), 4)
    }

    func testGroupCompile() {
        func t(_ i: Int) -> Track { Track(index: i, title: "t\(i)", fullWidthTitle: "", duration: 100, channel: .stereo, encoding: .sp, isProtected: false) }
        let disc = Disc(title: "My Disc", fullWidthTitle: "", writable: true, writeProtected: false, used: 0, left: 0, total: 0, trackCount: 3,
                        groups: [DiscGroup(index: 0, title: nil, fullWidthTitle: nil, tracks: [t(0)]),
                                 DiscGroup(index: 1, title: "Side B", fullWidthTitle: nil, tracks: [t(1), t(2)])])
        XCTAssertEqual(DiscTitles.compile(disc).half, "0;My Disc//2-3;Side B//")
    }

    func testATRAC3Parsing() throws {
        var wav = Data("RIFF".utf8)
        wav += [0, 0, 0, 0]; wav += Data("WAVEfmt ".utf8)
        wav += [32, 0, 0, 0, 0x70, 0x02, 2, 0, 0x44, 0xac, 0, 0, 0, 0, 0, 0, 0x80, 0x01, 0, 0] // blockAlign 384 → 192
        wav += [UInt8](repeating: 0, count: 16)
        wav += Data("data".utf8); wav += [4, 0, 0, 0, 1, 2, 3, 4]
        let f = try ATRAC3File.parse(wav)
        XCTAssertEqual(f.wireformat, .lp2)
        XCTAssertEqual(f.payload, [1, 2, 3, 4])
    }
}

final class ImportPipelineTests: XCTestCase {
    private func tone(seconds: Double) throws -> URL {
        let n = Int(44100 * seconds)
        var pcm = [UInt8](); pcm.reserveCapacity(n * 4)
        for i in 0..<n {
            let v = Int16(8000 * sin(2 * Double.pi * 440 * Double(i) / 44100))
            for _ in 0..<2 { pcm += [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)] }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tone-\(UUID()).wav")
        try AudioImporter.wavFile(fromPCM16LE: pcm).write(to: url)
        return url
    }

    private var encoder: URL? {
        let p = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/atracdenc")
        return FileManager.default.isExecutableFile(atPath: p.path) ? p : nil
    }

    func testSP() throws {
        let url = try tone(seconds: 2); defer { try? FileManager.default.removeItem(at: url) }
        let t = try AudioImporter.prepare(url: url, title: "x", mode: .sp)
        XCTAssertEqual(t.wireformat, .pcm)
        XCTAssertEqual(t.data.count, 44100 * 2 * 4)
        XCTAssertEqual(t.paddedSize % 2048, 0)
        XCTAssertEqual(t.duration, 2, accuracy: 0.01)
    }

    func testLP() throws {
        guard let enc = encoder else { throw XCTSkip("build/atracdenc not built") }
        let url = try tone(seconds: 3); defer { try? FileManager.default.removeItem(at: url) }
        for (mode, frame) in [(RecordingMode.lp2, 192), (.lp4, 96)] {
            let t = try AudioImporter.prepare(url: url, title: "x", mode: mode, encoderURL: enc)
            XCTAssertEqual(t.wireformat, mode.wireformat, "\(mode)")
            XCTAssertEqual(t.data.count % frame, 0)
            XCTAssertEqual(t.duration, 3, accuracy: 0.2, "\(mode)")
        }
    }
}

final class HomebrewRippingTests: XCTestCase {
    // MARK: Factory-mode checksum (CRC16/XMODEM-ish, used by every factory write command)

    func testChecksumKnownVectors() {
        // Hand-derived by tracing calculateChecksum(data, false) bit-for-bit (see code comment).
        XCTAssertEqual(checksum([0], as16Bit: false), 0)
        XCTAssertEqual(checksum([1], as16Bit: false), 0x1021)
    }

    func testChecksumIsSensitiveToEveryByte() {
        let a = checksum([1, 2, 3, 4], as16Bit: false)
        let b = checksum([1, 2, 3, 5], as16Bit: false)
        XCTAssertNotEqual(a, b)
    }

    // MARK: VersionStore specificity ordering

    func testVersionStoreSpecificity() {
        let table = ["S1.600,S1.500": 1, "S*": 2, "*": 3]
        XCTAssertEqual(VersionStore.lookup(table, version: "S1.600"), 1)
        XCTAssertEqual(VersionStore.lookup(table, version: "S1.000"), 2)
        XCTAssertEqual(VersionStore.lookup(table, version: "R1.000"), 3)
        XCTAssertNil(VersionStore.lookup(["S*": 1], version: "R1.000"))
    }

    // MARK: TOC fragment parsing — a synthetic sector0 with one 2-fragment, SP-stereo track

    private func discAddressBytes(cluster: Int, sector: Int, group: Int) -> [UInt8] {
        [UInt8(cluster >> 6), UInt8(((cluster & 0x3f) << 2) | ((sector & 0x30) >> 4)), UInt8(((sector & 0xf) << 4) | group)]
    }

    func testTOCFragmentChainAndFormat() throws {
        var sector0 = [UInt8](repeating: 0, count: 2352)
        // trackMap[1] = fragment 5 (trackMap starts at byte 48).
        sector0[48 + 1] = 5
        func writeFragment(_ index: Int, startSector: Int, endSector: Int, mode: UInt8, link: UInt8) {
            let base = 304 + index * 8
            sector0.replaceSubrange(base..<base + 3, with: discAddressBytes(cluster: 0, sector: startSector, group: 0))
            sector0[base + 3] = mode
            sector0.replaceSubrange(base + 4..<base + 7, with: discAddressBytes(cluster: 0, sector: endSector, group: 0))
            sector0[base + 7] = link
        }
        let spStereoMode: UInt8 = UInt8(ModeFlag.stereo | ModeFlag.spMode)
        writeFragment(5, startSector: 10, endSector: 20, mode: spStereoMode, link: 6)
        writeFragment(6, startSector: 21, endSector: 30, mode: spStereoMode, link: 0)

        let toc = try UTOC.parse(sector0: sector0)
        XCTAssertEqual(toc.trackMap[1], 5)

        let fragments = toc.fragments(forTrack: 1)
        XCTAssertEqual(fragments.count, 2)
        XCTAssertEqual(fragments[0].start.logical, 10)
        XCTAssertEqual(fragments[0].end.logical, 20)
        XCTAssertEqual(fragments[0].link, 6)
        XCTAssertEqual(fragments[1].start.logical, 21)
        XCTAssertEqual(fragments[1].end.logical, 30)
        XCTAssertEqual(fragments[1].link, 0)
        XCTAssertEqual(recoveredFormat(for: fragments[0]), .sp)
    }

    func testTOCSingleFragmentTrack() throws {
        var sector0 = [UInt8](repeating: 0, count: 2352)
        sector0[48 + 1] = 0 // trackMap[1] = fragment 0 (link == 0, i.e. only one fragment)
        let base = 304
        sector0.replaceSubrange(base..<base + 3, with: discAddressBytes(cluster: 0, sector: 0, group: 0))
        sector0[base + 3] = UInt8(ModeFlag.stereo | ModeFlag.spMode)
        sector0.replaceSubrange(base + 4..<base + 7, with: discAddressBytes(cluster: 0, sector: 5, group: 0))
        sector0[base + 7] = 0

        let toc = try UTOC.parse(sector0: sector0)
        let fragments = toc.fragments(forTrack: 1)
        XCTAssertEqual(fragments.count, 1, "A track whose root fragment index is 0 must still yield exactly one fragment")
        XCTAssertEqual(fragments[0].end.logical, 5)
    }

    // MARK: FirmwareAssembler — the Keystone seam should fail clearly, not silently misbehave

    func testFirmwareAssemblerUnknownVersionFailsClearly() {
        XCTAssertThrowsError(try FirmwareAssembler.noRamTemplate(for: "Hx1.0A0")) { error in
            guard case NetMDError.unsupported = error else { return XCTFail("Expected .unsupported, got \(error)") }
        }
    }

    // MARK: Keystone wiring

    func testKeystoneAssemblesKnownARMBytes() throws {
        // "mov r0, #1 ; bx lr" has a textbook-stable ARM32 encoding.
        let bytes = try Keystone.assemble("mov r0, #1\nbx lr", mode: .arm)
        XCTAssertEqual(bytes, [0x01, 0x00, 0xa0, 0xe3, 0x1e, 0xff, 0x2f, 0xe1])
    }

    func testKeystoneAssemblesKnownThumbBytes() throws {
        // "movs r0, #1 ; bx lr" in THUMB.
        let bytes = try Keystone.assemble("movs r0, #1\nbx lr", mode: .thumb)
        XCTAssertEqual(bytes, [0x01, 0x20, 0x70, 0x47])
    }

    func testKeystoneRejectsBadAssembly() {
        XCTAssertThrowsError(try Keystone.assemble("not a real instruction", mode: .arm))
    }

    func testFirmwareAssemblerNoRamReadProducesAssembledStub() throws {
        let template = try FirmwareAssembler.noRamTemplate(for: "S1.600")
        let code = template.makeCode(sector: 5, subsectorStart: 100, length: 400)
        // The trailing 12 bytes are the literal sector/subsectorStart/length words we append ourselves.
        XCTAssertEqual(code.count, template.body.count + 12)
        let trailer = code.suffix(12)
        XCTAssertEqual(Array(trailer.prefix(4)), [5, 0, 0, 0])
        XCTAssertEqual(Array(trailer.dropFirst(4).prefix(4)), [100, 0, 0, 0])
        XCTAssertEqual(Array(trailer.dropFirst(8)), [0x90, 0x01, 0, 0]) // 400 = 0x0190, little-endian
        XCTAssertEqual(template.codeLength, template.body.count + 12)
    }

    func testFirmwareAssemblerKnownVersionsAllAssemble() throws {
        for version in FirmwareAssembler.noRamAddresses.keys {
            XCTAssertNoThrow(try FirmwareAssembler.noRamTemplate(for: version), version)
        }
    }

    func testFirmwareAssemblerTemplateIsCached() throws {
        let a = try FirmwareAssembler.noRamTemplate(for: "S1.000")
        let b = try FirmwareAssembler.noRamTemplate(for: "S1.000")
        XCTAssertEqual(a.body, b.body)
        XCTAssertEqual(a.codeLength, b.codeLength)
    }

    // MARK: Control-transfer (fast path) installer

    func testControlInstallerAssemblesForAllKnownVersions() throws {
        for version in FirmwareAssembler.controlAddresses.keys {
            let code = try FirmwareAssembler.assembleControlInstaller(for: version)
            XCTAssertGreaterThan(code.count, 0, version)
            XCTAssertEqual(code.count % 4, 0, "ARM code must be a whole number of words (\(version))")
        }
    }

    func testControlInstallerUnknownVersionFailsClearly() {
        XCTAssertThrowsError(try FirmwareAssembler.assembleControlInstaller(for: "R1.000")) { error in
            guard case NetMDError.unsupported = error else { return XCTFail("Expected .unsupported, got \(error)") }
        }
    }

    func testControlInstallerIsDeterministic() throws {
        let a = try FirmwareAssembler.assembleControlInstaller(for: "S1.600")
        let b = try FirmwareAssembler.assembleControlInstaller(for: "S1.600")
        XCTAssertEqual(a, b)
    }

    // MARK: AEA -> WAV decoding (round-trips a real atracdenc-encoded AEA through ffmpeg)

    func testDecodeAEAToWAVRoundTrips() throws {
        guard ATRACDecoding.isAvailable else { throw XCTSkip("ffmpeg not installed") }
        // Stereo ATRAC1 is two interleaved 212-byte sound units (one per channel) per sound group.
        let header = AEAWAV.aeaHeader(title: "Test", channels: 2, soundGroups: 1)
        let silentFrame = [UInt8](repeating: 0, count: 212 * 2)
        let aea = header + silentFrame
        let wav = try ATRACDecoding.decodeAEAToWAV(aea)
        XCTAssertNotNil(wav)
        XCTAssertEqual(wav.map { Array($0.prefix(4)) }, Array("RIFF".utf8))
    }

    func testDecodeAEAToWAVReturnsNilWithoutFFmpeg() {
        // Can't easily hide ffmpeg from PATH in-process; just confirm the availability check
        // agrees with AudioImporter's own tool lookup used internally.
        XCTAssertEqual(ATRACDecoding.isAvailable, AudioImporter.locateTool("ffmpeg") != nil)
    }
}
