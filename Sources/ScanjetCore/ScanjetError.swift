import Foundation

public enum ScanjetError: Error, CustomStringConvertible, LocalizedError, Sendable {
    case usb(String)
    case protocolMismatch(String)
    case io(String)
    case usage(String)
    case cancelled

    public var description: String {
        switch self {
        case .usb(let message): return message
        case .protocolMismatch(let message): return message
        case .io(let message): return message
        case .usage(let message): return message
        case .cancelled: return "The scan was stopped."
        }
    }

    public var errorDescription: String? { description }
}

public func hex(_ value: some BinaryInteger, width: Int = 2) -> String {
    String(format: "%0\(width)x", Int(value))
}
