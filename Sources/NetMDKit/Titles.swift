import Foundation

/// Title encoding helpers. MiniDisc titles are stored as Shift-JIS; half-width titles may only contain
/// ASCII and half-width katakana, full-width titles only double-byte characters.
public enum Titles {
    public static func encodeSJIS(_ s: String) -> [UInt8] {
        // Shift-JIS keeps ASCII and half-width kana as single bytes.
        [UInt8](s.data(using: .shiftJIS, allowLossyConversion: true) ?? Data())
    }

    public static func decodeSJIS(_ bytes: [UInt8]) -> String {
        String(data: Data(bytes), encoding: .shiftJIS) ?? String(decoding: bytes, as: UTF8.self)
    }

    public static func sjisLength(_ s: String) -> Int { encodeSJIS(s).count }

    /// Characters outside ASCII/half-width kana are replaced by spaces; accents are stripped.
    public static func sanitizeHalfWidth(_ title: String) -> String {
        // Fold full-width ASCII/kana/hiragana to half-width kana (dakuten become separate marks).
        var s = title.applyingTransform(.hiraganaToKatakana, reverse: false) ?? title
        s = s.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? s
        s = s.replacingOccurrences(of: "ー", with: "-").replacingOccurrences(of: "\u{FF70}", with: "-")
        s = s.replacingOccurrences(of: "\u{3000}", with: " ")
        // Compatibility: Cyrillic and German are transliterated, like upstream does.
        s = transliterate(s)

        var mapped = ""
        for ch in s {
            if let u = ch.unicodeScalars.first, ch.unicodeScalars.count == 1, isAllowedHalfWidth(u) {
                mapped.append(ch)
                continue
            }
            let folded = String(ch).folding(options: [.diacriticInsensitive], locale: nil)
            if folded.unicodeScalars.allSatisfy(isAllowedHalfWidth) { mapped.append(folded) } else { mapped.append(" ") }
        }
        if sjisLength(mapped) != mapped.utf16.count { return aggressiveSanitize(title) }
        return mapped
    }

    private static func isAllowedHalfWidth(_ u: Unicode.Scalar) -> Bool {
        (u.value >= 0x20 && u.value < 0x7f) || (u.value >= 0xFF61 && u.value <= 0xFF9F)
    }

    public static func sanitizeFullWidth(_ title: String) -> String {
        var s = transliterate(title)
        s = s.applyingTransform(.fullwidthToHalfwidth, reverse: true) ?? s
        s = s.replacingOccurrences(of: " ", with: "\u{3000}")
        // Every character must be exactly two Shift-JIS bytes, otherwise the TOC can be corrupted.
        if sjisLength(s) != s.utf16.count * 2 { return aggressiveSanitize(title) }
        return s
    }

    public static func aggressiveSanitize(_ title: String) -> String {
        String(title.folding(options: [.diacriticInsensitive], locale: nil).unicodeScalars.filter { $0.value < 0x80 })
    }

    private static func transliterate(_ s: String) -> String {
        var out = s
        let german = ["Ä": "Ae", "ä": "ae", "Ö": "Oe", "ö": "oe", "Ü": "Ue", "ü": "ue", "ß": "ss"]
        for (k, v) in german { out = out.replacingOccurrences(of: k, with: v) }
        if out.unicodeScalars.contains(where: { (0x400...0x4FF).contains($0.value) }) {
            out = out.applyingTransform(.toLatin, reverse: false) ?? out
            out = out.folding(options: [.diacriticInsensitive], locale: nil)
        }
        return out
    }

    /// Number of bytes a half-width title occupies in the TOC.
    public static func halfWidthLength(_ title: String) -> Int {
        let hw = title.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? title
        let n = sjisLength(hw)
        return n > 0 ? n : title.utf16.count
    }

    /// Full-width digits/punctuation used when writing group ranges (e.g. `1-3` → `１－３`).
    public static func halfWidthToFullWidthRange(_ range: String) -> String {
        let map: [Character: Character] = [
            "0": "０", "1": "１", "2": "２", "3": "３", "4": "４", "5": "５", "6": "６", "7": "７", "8": "８", "9": "９",
            "-": "－", "/": "／", ";": "；",
        ]
        return String(range.map { map[$0] ?? $0 })
    }
}
