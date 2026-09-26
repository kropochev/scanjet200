import Foundation
import CoreGraphics

public enum PhotoSubject: String, CaseIterable, Sendable {
    case colourPrint
    case blackAndWhitePrint
    case colourNegative
    case blackAndWhiteNegative

    public var isNegative: Bool {
        self == .colourNegative || self == .blackAndWhiteNegative
    }

    public var isColour: Bool {
        self == .colourPrint || self == .colourNegative
    }

    public var defaultDPI: Int {
        isNegative ? 1200 : 600
    }

    public static func parseCLI(_ raw: String) throws -> PhotoSubject {
        switch raw.lowercased() {
        case "colour-print", "color-print", "print":
            return .colourPrint
        case "bw-print", "grey-print", "gray-print", "black-and-white-print":
            return .blackAndWhitePrint
        case "colour-negative", "color-negative", "negative":
            return .colourNegative
        case "bw-negative", "grey-negative", "gray-negative", "black-and-white-negative":
            return .blackAndWhiteNegative
        default:
            throw ScanjetError.usage(
                "photo-subject: colour-print | bw-print | colour-negative | bw-negative"
            )
        }
    }
}

public enum PhotoLayout: String, CaseIterable, Sendable {
    case prints
    case filmStrip

    public var isFilm: Bool { self == .filmStrip }

    public static func parseCLI(_ raw: String) throws -> PhotoLayout {
        switch raw.lowercased() {
        case "prints", "print", "photos":
            return .prints
        case "strip", "35mm", "35-mm", "film", "film-strip", "filmstrip":
            return .filmStrip
        default:
            throw ScanjetError.usage("photo-layout: prints | strip")
        }
    }
}

/// Frame size along a film strip. GOST / DIN / ASA numbers are speed, not this.
public enum PhotoFilmFormat: String, CaseIterable, Sendable {
    case auto
    case mm35
    case mm35Half
    case mm120_6x45
    case mm120_6x6
    case mm120_6x9
    case mm16
    case mm110
    case mm127

    /// Width of the film stock across the strip, millimetres (including sprockets).
    public var stockWidthMM: Double {
        switch self {
        case .auto, .mm35, .mm35Half: return 35
        case .mm120_6x45, .mm120_6x6, .mm120_6x9: return 61.5
        case .mm16, .mm110: return 16
        case .mm127: return 46
        }
    }

    /// Typical advance along the strip, including the gap, millimetres.
    public var framePitchMM: Double {
        switch self {
        case .auto, .mm35: return 38
        case .mm35Half: return 19
        case .mm120_6x45: return 45
        case .mm120_6x6: return 62
        case .mm120_6x9: return 87.5
        case .mm16: return 15.2
        case .mm110: return 20
        case .mm127: return 46.5
        }
    }

    public func resolved(for strip: ScanRegion) -> PhotoFilmFormat {
        self == .auto ? PhotoFilmFormat.inferred(from: strip) : self
    }

    public static func inferred(from strip: ScanRegion) -> PhotoFilmFormat {
        let across = min(strip.widthMM, strip.heightMM)
        let along = max(strip.widthMM, strip.heightMM)
        let candidates: [PhotoFilmFormat]
        if across < 24 {
            candidates = [.mm110, .mm16]
        } else if across < 42 {
            candidates = [.mm35, .mm35Half]
        } else if across < 53 {
            candidates = [.mm127]
        } else {
            candidates = [.mm120_6x6, .mm120_6x45, .mm120_6x9]
        }
        return candidates.min { a, b in
            let ea = pitchError(along: along, pitch: a.framePitchMM)
            let eb = pitchError(along: along, pitch: b.framePitchMM)
            if abs(ea - eb) < 0.06 {
                return (candidates.firstIndex(of: a) ?? 0) < (candidates.firstIndex(of: b) ?? 0)
            }
            return ea < eb
        } ?? .mm35
    }

    private static func pitchError(along: Double, pitch: Double) -> Double {
        let count = along / max(pitch, 1)
        return abs(count - count.rounded())
    }

    public static func parseCLI(_ raw: String) throws -> PhotoFilmFormat {
        switch raw.lowercased() {
        case "auto": return .auto
        case "35mm", "35-mm", "135", "24x36": return .mm35
        case "half-frame", "halfframe", "18x24", "35mm-half": return .mm35Half
        case "6x4.5", "6x45", "120-6x45", "645": return .mm120_6x45
        case "6x6", "120", "120-6x6": return .mm120_6x6
        case "6x9", "120-6x9": return .mm120_6x9
        case "16mm", "16-mm": return .mm16
        case "110": return .mm110
        case "127", "4x4": return .mm127
        default:
            throw ScanjetError.usage(
                "photo-format: auto | 35mm | half-frame | 6x4.5 | 6x6 | 6x9 | 16mm | 110 | 127"
            )
        }
    }
}

public struct PhotoSettings: Equatable, Sendable {
    public var subject: PhotoSubject = .colourPrint
    public var layout: PhotoLayout = .prints
    public var filmFormat: PhotoFilmFormat = .auto
    /// Inset applied when saving, in millimetres (0, 1, or 2).
    public var cropMarginMM: Int = 0
    public var straighten = true
    public var invertToPositive = true
    public var autoLevels = true
    public var orangeMask = true

    public init(
        subject: PhotoSubject = .colourPrint,
        layout: PhotoLayout = .prints,
        filmFormat: PhotoFilmFormat = .auto,
        cropMarginMM: Int = 0,
        straighten: Bool = true,
        invertToPositive: Bool = true,
        autoLevels: Bool = true,
        orangeMask: Bool = true
    ) {
        self.subject = subject
        self.layout = layout
        self.filmFormat = filmFormat
        self.cropMarginMM = cropMarginMM
        self.straighten = straighten
        self.invertToPositive = invertToPositive
        self.autoLevels = autoLevels
        self.orangeMask = orangeMask
    }

    public var effectiveMarginMM: Double {
        Double(min(2, max(0, cropMarginMM)))
    }

    public var effectiveInvert: Bool {
        subject.isNegative && invertToPositive
    }

    public var effectiveOrangeMask: Bool {
        subject == .colourNegative && orangeMask
    }

    public var effectiveAutoLevels: Bool {
        subject.isNegative && autoLevels
    }
}

/// One photo or film frame on the glass, in millimetres.
public struct PhotoFrame: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var region: ScanRegion
    /// Detector deskew of the content inside `region`, degrees clockwise.
    public var angleDegrees: Double
    /// Extra 90° turns the user applied in review.
    public var extraRotation: ScanOrientation

    public init(
        id: UUID = UUID(),
        region: ScanRegion,
        angleDegrees: Double = 0,
        extraRotation: ScanOrientation = .deg0
    ) {
        self.id = id
        self.region = region
        self.angleDegrees = angleDegrees
        self.extraRotation = extraRotation
    }

    public func rotating90Clockwise() -> PhotoFrame {
        var copy = self
        switch extraRotation {
        case .deg0: copy.extraRotation = .deg90
        case .deg90: copy.extraRotation = .deg180
        case .deg180: copy.extraRotation = .deg270
        case .deg270: copy.extraRotation = .deg0
        }
        return copy
    }
}

public struct PhotoDetectionResult: Sendable {
    public var frames: [PhotoFrame]
    public var stripBounds: ScanRegion?
    public var filmFormat: PhotoFilmFormat?

    public init(frames: [PhotoFrame], stripBounds: ScanRegion? = nil, filmFormat: PhotoFilmFormat? = nil) {
        self.frames = frames
        self.stripBounds = stripBounds
        self.filmFormat = filmFormat
    }
}

public struct PhotoReviewSession: Sendable {
    public var captureURL: URL
    public var previewURL: URL?
    public var region: ScanRegion
    public var dpi: Int
    public var width: Int
    public var height: Int
    public var frames: [PhotoFrame]
    public var stripBounds: ScanRegion?
    public var framesWereEdited: Bool
    public var detectedFilmFormat: PhotoFilmFormat?

    public init(
        captureURL: URL,
        previewURL: URL? = nil,
        region: ScanRegion,
        dpi: Int,
        width: Int,
        height: Int,
        frames: [PhotoFrame],
        stripBounds: ScanRegion? = nil,
        framesWereEdited: Bool = false,
        detectedFilmFormat: PhotoFilmFormat? = nil
    ) {
        self.captureURL = captureURL
        self.previewURL = previewURL
        self.region = region
        self.dpi = dpi
        self.width = width
        self.height = height
        self.frames = frames
        self.stripBounds = stripBounds
        self.framesWereEdited = framesWereEdited
        self.detectedFilmFormat = detectedFilmFormat
    }

    public func removeTemporaryFiles() {
        try? FileManager.default.removeItem(at: captureURL)
        if let previewURL {
            try? FileManager.default.removeItem(at: previewURL)
        }
    }
}

public enum PhotoGeometry {
    public static func pixelRect(
        for region: ScanRegion,
        capture: ScanRegion,
        imageWidth: Int,
        imageHeight: Int
    ) -> CGRect {
        let sx = Double(imageWidth) / max(capture.widthMM, 0.001)
        let sy = Double(imageHeight) / max(capture.heightMM, 0.001)
        return CGRect(
            x: (region.xMM - capture.xMM) * sx,
            y: (region.yMM - capture.yMM) * sy,
            width: region.widthMM * sx,
            height: region.heightMM * sy
        )
    }

    public static func region(
        fromPixel rect: CGRect,
        capture: ScanRegion,
        imageWidth: Int,
        imageHeight: Int
    ) -> ScanRegion {
        let sx = capture.widthMM / max(Double(imageWidth), 1)
        let sy = capture.heightMM / max(Double(imageHeight), 1)
        return ScanRegion(
            xMM: capture.xMM + Double(rect.minX) * sx,
            yMM: capture.yMM + Double(rect.minY) * sy,
            widthMM: Double(rect.width) * sx,
            heightMM: Double(rect.height) * sy
        )
    }

    public static func sorted(_ frames: [PhotoFrame]) -> [PhotoFrame] {
        frames.sorted { a, b in
            if abs(a.region.yMM - b.region.yMM) > 8 {
                return a.region.yMM < b.region.yMM
            }
            return a.region.xMM < b.region.xMM
        }
    }
}

extension ScanRegion {
    public func inset(byMM mm: Double) -> ScanRegion {
        let inset = max(0, mm)
        let width = max(1, widthMM - 2 * inset)
        let height = max(1, heightMM - 2 * inset)
        return ScanRegion(
            xMM: xMM + inset,
            yMM: yMM + inset,
            widthMM: width,
            heightMM: height
        )
    }

    public func expanded(byMM mm: Double) -> ScanRegion {
        ScanRegion(
            xMM: xMM - mm,
            yMM: yMM - mm,
            widthMM: widthMM + 2 * mm,
            heightMM: heightMM + 2 * mm
        )
    }

    public func clamped(to bounds: ScanRegion) -> ScanRegion {
        let x = min(max(xMM, bounds.xMM), bounds.xMM + bounds.widthMM)
        let y = min(max(yMM, bounds.yMM), bounds.yMM + bounds.heightMM)
        let maxW = bounds.xMM + bounds.widthMM - x
        let maxH = bounds.yMM + bounds.heightMM - y
        return ScanRegion(
            xMM: x,
            yMM: y,
            widthMM: min(max(1, widthMM), max(1, maxW)),
            heightMM: min(max(1, heightMM), max(1, maxH))
        )
    }

    public func contains(_ other: ScanRegion, slackMM: Double = 1) -> Bool {
        other.xMM >= xMM - slackMM
            && other.yMM >= yMM - slackMM
            && other.xMM + other.widthMM <= xMM + widthMM + slackMM
            && other.yMM + other.heightMM <= yMM + heightMM + slackMM
    }

    public var areaMM: Double { max(0, widthMM) * max(0, heightMM) }

    public static func union(_ regions: [ScanRegion]) -> ScanRegion? {
        guard let first = regions.first else { return nil }
        var minX = first.xMM
        var minY = first.yMM
        var maxX = first.xMM + first.widthMM
        var maxY = first.yMM + first.heightMM
        for region in regions.dropFirst() {
            minX = min(minX, region.xMM)
            minY = min(minY, region.yMM)
            maxX = max(maxX, region.xMM + region.widthMM)
            maxY = max(maxY, region.yMM + region.heightMM)
        }
        return ScanRegion(xMM: minX, yMM: minY, widthMM: maxX - minX, heightMM: maxY - minY)
    }
}
