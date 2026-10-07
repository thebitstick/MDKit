import Foundation

public enum NetMDError: Error, LocalizedError {
    case notImplemented(String)
    case rejected(String)
    case usb(String)
    case protocolError(String)
    case unsupported(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notImplemented(let m): return "Not implemented by the device: \(m)"
        case .rejected(let m): return "The device rejected the command (\(m))"
        case .usb(let m): return "USB error: \(m)"
        case .protocolError(let m): return "Protocol error: \(m)"
        case .unsupported(let m): return m
        case .cancelled: return "Cancelled"
        }
    }
}
