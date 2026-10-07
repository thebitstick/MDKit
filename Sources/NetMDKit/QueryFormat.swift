import Foundation

/// Argument for `formatQuery`.
public enum QArg {
    case int(UInt64)
    case bytes([UInt8])

    public static func b(_ v: Int) -> QArg { .int(UInt64(truncatingIfNeeded: v)) }
}

public enum QValue {
    case int(UInt64)
    case bytes([UInt8])

    public var intValue: Int {
        if case .int(let v) = self { return Int(truncatingIfNeeded: v) }
        return 0
    }
    public var bytesValue: [UInt8] {
        if case .bytes(let v) = self { return v }
        return []
    }
}

/// Port of netmd-js `formatQuery` / `scanQuery`.
///
/// Format language: hex byte pairs (whitespace ignored) plus
/// `%b %w %d %q` (1/2/4/8-byte ints, optional `<`/`>` endianness prefix after `%`),
/// `%s %x` (2-byte length + data, `%s` adds a trailing NUL), `%z` (1-byte length + data),
/// `%*` (raw bytes), `%B %W` (BCD 1/2 bytes), and for scanning `%?` (skip byte) and `%#` (rest).
public enum Query {
    private static func intSize(_ c: Character) -> Int? {
        switch c { case "b": return 1; case "w": return 2; case "d": return 4; case "q": return 8; default: return nil }
    }

    public static func format(_ fmt: String, _ args: QArg...) throws -> [UInt8] {
        try format(fmt, args: args)
    }

    public static func format(_ fmt: String, args: [QArg]) throws -> [UInt8] {
        var out = [UInt8]()
        var half: Character?
        var escaped = false
        var little = false
        var stack = args[...]

        for ch in fmt {
            if escaped {
                if ch == "<" { little = true; continue }
                if ch == ">" { little = false; continue }
                escaped = false
                guard let arg = stack.popFirst() else { throw NetMDError.protocolError("formatQuery: missing argument for %\(ch)") }
                if let size = intSize(ch) {
                    guard case .int(let v) = arg else { throw NetMDError.protocolError("formatQuery: expected int for %\(ch)") }
                    for i in 0..<size {
                        let shift = little ? i * 8 : (size - 1 - i) * 8
                        out.append(UInt8((v >> UInt64(shift)) & 0xff))
                    }
                    little = false
                } else if ch == "x" || ch == "s" || ch == "z" {
                    guard case .bytes(let v) = arg else { throw NetMDError.protocolError("formatQuery: expected bytes for %\(ch)") }
                    var len = v.count
                    if ch == "s" { len += 1 }
                    if ch != "z" { out.append(UInt8((len >> 8) & 0xff)) }
                    out.append(UInt8(len & 0xff))
                    out.append(contentsOf: v)
                    if ch == "s" { out.append(0) }
                } else if ch == "*" {
                    guard case .bytes(let v) = arg else { throw NetMDError.protocolError("formatQuery: expected bytes for %*") }
                    out.append(contentsOf: v)
                } else if ch == "B" || ch == "W" {
                    guard case .int(let v) = arg else { throw NetMDError.protocolError("formatQuery: expected int for %\(ch)") }
                    let bcd = try int2BCD(Int(v), length: ch == "W" ? 2 : 1)
                    if ch == "W" { out.append(UInt8((bcd >> 8) & 0xff)) }
                    out.append(UInt8(bcd & 0xff))
                } else {
                    throw NetMDError.protocolError("formatQuery: unknown format char \(ch)")
                }
                continue
            }
            if ch == "%" { escaped = true; continue }
            if ch == " " { continue }
            if let h = half {
                guard let byte = UInt8(String([h, ch]), radix: 16) else { throw NetMDError.protocolError("formatQuery: bad hex \(h)\(ch)") }
                out.append(byte)
                half = nil
            } else {
                half = ch
            }
        }
        return out
    }

    @discardableResult
    public static func scan(_ input: [UInt8], _ fmt: String) throws -> [QValue] {
        var stack = ArraySlice(input)
        var result = [QValue]()
        var half: Character?
        var escaped = false
        var little = false

        func next() throws -> UInt8 {
            guard let b = stack.popFirst() else { throw NetMDError.protocolError("scanQuery: input too short (format \(fmt))") }
            return b
        }

        for ch in fmt {
            if escaped {
                if ch == "<" { little = true; continue }
                if ch == ">" { little = false; continue }
                escaped = false
                if ch == "?" { _ = try next(); continue }
                if let size = intSize(ch) {
                    var v: UInt64 = 0
                    for i in 0..<size {
                        let shift = little ? i * 8 : (size - 1 - i) * 8
                        v |= UInt64(try next()) << UInt64(shift)
                    }
                    little = false
                    result.append(.int(v))
                } else if ch == "s" || ch == "x" || ch == "z" {
                    let len = ch == "z" ? Int(try next()) : (Int(try next()) << 8 | Int(try next()))
                    guard stack.count >= len else { throw NetMDError.protocolError("scanQuery: truncated field") }
                    result.append(.bytes(Array(stack.prefix(len))))
                    stack = stack.dropFirst(len)
                } else if ch == "*" || ch == "#" {
                    result.append(.bytes(Array(stack)))
                    stack = []
                } else if ch == "B" {
                    result.append(.int(UInt64(bcd2int(UInt32(try next())))))
                } else if ch == "W" {
                    let v = UInt32(try next()) << 8 | UInt32(try next())
                    result.append(.int(UInt64(bcd2int(v))))
                } else {
                    throw NetMDError.protocolError("scanQuery: unknown format char \(ch)")
                }
                continue
            }
            if ch == "%" { escaped = true; continue }
            if ch == " " { continue }
            if let h = half {
                guard let expected = UInt8(String([h, ch]), radix: 16) else { throw NetMDError.protocolError("scanQuery: bad hex in format") }
                let got = try next()
                if got != expected {
                    throw NetMDError.protocolError("scanQuery: mismatch, expected \(String(expected, radix: 16)) got \(String(got, radix: 16)) (format \(fmt))")
                }
                half = nil
            } else {
                half = ch
            }
        }
        if !stack.isEmpty { throw NetMDError.protocolError("scanQuery: \(stack.count) bytes remaining (format \(fmt))") }
        return result
    }

    public static func bcd2int(_ bcd: UInt32) -> Int {
        var v = bcd, out = 0, mul = 1
        while v != 0 { out += Int(v & 0xf) * mul; mul *= 10; v >>= 4 }
        return out
    }

    public static func int2BCD(_ value: Int, length: Int = 1) throws -> Int {
        var v = value, out = 0, nibble = 0
        var limit = 1; for _ in 0..<(length * 2) { limit *= 10 }
        guard value < limit else { throw NetMDError.protocolError("BCD overflow: \(value)") }
        while v > 0 { out |= (v % 10) << (4 * nibble); v /= 10; nibble += 1 }
        return out
    }
}
