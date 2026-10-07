import Foundation

/// Matches firmware-version keys like `"S1.600"`, `"S*"`, `"R1.000,R1.100"`, `"*"` against an
/// exact version string. Ported from netmd-exploits' `getFromVersionStore` — the device-specific
/// RAM addresses used by the factory-mode patches are keyed this way, most specifically first.
public enum VersionStore {
    public static func matches(_ pattern: String, _ version: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: pattern).replacingOccurrences(of: "\\*", with: ".*")
        guard let re = try? NSRegularExpression(pattern: "^\(escaped)$") else { return false }
        return re.firstMatch(in: version, range: NSRange(version.startIndex..., in: version)) != nil
    }

    /// `table` maps comma-separated version patterns to a value. Returns the most specific match:
    /// an exact listing beats a wildcard pattern beats `"*"`.
    public static func lookup<T>(_ table: [String: T], version: String) -> T? {
        var exact: T?, wildcard: T?, global: T?
        for (key, value) in table {
            let parts = key.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.contains(version) { exact = value }
            for part in parts {
                if part == "*" { global = value }
                else if matches(part, version) { wildcard = value }
            }
        }
        return exact ?? wildcard ?? global
    }

    public static func require<T>(_ table: [String: T], version: String, _ name: String = "") throws -> T {
        guard let v = lookup(table, version: version) else {
            throw NetMDError.unsupported("Firmware version \(version) is not supported\(name.isEmpty ? "" : " for \(name)")")
        }
        return v
    }
}
