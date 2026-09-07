import Foundation

/// Cooperative cancel flag shared by the UI thread and the capture thread.
/// USB bulk reads are synchronous, so the engine checks this between chunks
/// and inside wait loops rather than aborting a transfer in flight.
public final class ScanCancel: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false

    public init() {}

    public var isRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }

    public func request() {
        lock.lock()
        requested = true
        lock.unlock()
    }

    public func throwIfRequested() throws {
        if isRequested {
            throw ScanjetError.cancelled
        }
    }
}
