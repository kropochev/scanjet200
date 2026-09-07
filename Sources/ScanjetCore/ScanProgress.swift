import Foundation

public struct LivePreviewBand: Sendable {
    public var width: Int
    public var height: Int
    public var y: Int
    public var rows: Int
    public var rgba: Data
}

public struct ScanProgress: Sendable {
    public enum Phase: Sendable {
        case preparing
        case capturing
        case decoding
        case exporting
        case homing
        case done
    }

    public var phase: Phase
    /// 0…1 within the current phase when known.
    public var fraction: Double
    public var message: String
    public var livePreview: LivePreviewBand?

    public init(phase: Phase, fraction: Double = 0, message: String = "", livePreview: LivePreviewBand? = nil) {
        self.phase = phase
        self.fraction = fraction
        self.message = message
        self.livePreview = livePreview
    }
}

public typealias ScanProgressHandler = @Sendable (ScanProgress) -> Void

public enum ScanLogger {
    public static var handler: ScanProgressHandler?

    public static func log(_ phase: ScanProgress.Phase, _ fraction: Double = 0, _ message: String = "",
                           livePreview: LivePreviewBand? = nil) {
        handler?(ScanProgress(phase: phase, fraction: fraction, message: message, livePreview: livePreview))
    }

    public static func print(_ message: String) {
        handler?(ScanProgress(phase: .preparing, fraction: 0, message: message))
    }
}
