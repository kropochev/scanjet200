import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public enum ScanKind: String, CaseIterable, Sendable {
    case colour
    case blackAndWhite
    case text
    case photo
}

public enum ColorDepth: String, CaseIterable, Sendable {
    case millions
    case billions
}

public enum PaperSize: String, CaseIterable, Sendable {
    case a4
    case usLetter

    public var widthMM: Double {
        switch self {
        case .a4: return 210
        case .usLetter: return 215.9
        }
    }

    public var heightMM: Double {
        switch self {
        case .a4: return 297
        case .usLetter: return 279.4
        }
    }
}

public enum ScanOrientation: Int, CaseIterable, Sendable {
    case deg0 = 0
    case deg90 = 90
    case deg180 = 180
    case deg270 = 270
}

public enum OutputFormat: String, CaseIterable, Sendable {
    case jpeg
    case heic
    case tiff
    case png
    case jpeg2000
    case gif
    case bmp
    case pdf

    public var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .heic: return "heic"
        case .tiff: return "tiff"
        case .png: return "png"
        case .jpeg2000: return "jp2"
        case .gif: return "gif"
        case .bmp: return "bmp"
        case .pdf: return "pdf"
        }
    }

    public var supportsCombine: Bool {
        self == .pdf || self == .tiff
    }

    public var supportsBillions: Bool {
        switch self {
        case .tiff, .png: return true
        default: return false
        }
    }

    /// ImageIO UTI for encoding. Throws instead of substituting another container
    /// (the old JPEG 2000 path wrote PNG under a `.jp2` name).
    func imageIOType() throws -> UTType {
        let type: UTType
        switch self {
        case .jpeg: type = .jpeg
        case .heic: type = .heic
        case .tiff: type = .tiff
        case .png: type = .png
        case .jpeg2000:
            guard let jpeg2000 = UTType("public.jpeg-2000") else {
                throw ScanjetError.io("JPEG 2000 is not available on this Mac")
            }
            type = jpeg2000
        case .gif: type = .gif
        case .bmp: type = .bmp
        case .pdf: type = .pdf
        }
        let supported = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        guard supported.contains(type.identifier) else {
            throw ScanjetError.io("\(rawValue) is not available on this Mac")
        }
        return type
    }

    public static func fromFileExtension(_ ext: String) -> OutputFormat? {
        switch ext.lowercased() {
        case "jpg", "jpeg": return .jpeg
        case "heic": return .heic
        case "tiff", "tif": return .tiff
        case "png": return .png
        case "jp2", "jpx": return .jpeg2000
        case "gif": return .gif
        case "bmp": return .bmp
        case "pdf": return .pdf
        default: return nil
        }
    }

    public static func parseCLI(_ raw: String) throws -> OutputFormat {
        if let format = fromFileExtension(raw) { return format }
        switch raw.lowercased() {
        case "jpeg2000", "jpeg-2000": return .jpeg2000
        default:
            throw ScanjetError.usage("format: jpeg | heic | tiff | png | jp2 | gif | bmp | pdf")
        }
    }
}

extension ScanKind {
    public static func parseCLI(_ raw: String) throws -> ScanKind {
        switch raw.lowercased() {
        case "colour", "color": return .colour
        case "black-and-white", "blackandwhite", "bw", "gray", "grey", "grayscale", "greyscale":
            return .blackAndWhite
        case "text": return .text
        case "photo": return .photo
        default:
            throw ScanjetError.usage("kind: colour | gray | text | photo")
        }
    }
}

extension ColorDepth {
    public static func parseCLI(_ raw: String) throws -> ColorDepth {
        switch raw.lowercased() {
        case "millions", "8", "8-bit", "8bit": return .millions
        case "billions", "16", "16-bit", "16bit": return .billions
        default:
            throw ScanjetError.usage("colours: millions | billions")
        }
    }
}

extension PaperSize {
    public static func parseCLI(_ raw: String) throws -> PaperSize {
        switch raw.lowercased() {
        case "a4": return .a4
        case "letter", "us-letter", "usletter", "us_letter": return .usLetter
        default:
            throw ScanjetError.usage("size: a4 | letter")
        }
    }
}

extension ScanOrientation {
    public static func parseCLI(_ raw: String) throws -> ScanOrientation {
        switch raw {
        case "0": return .deg0
        case "90": return .deg90
        case "180": return .deg180
        case "270": return .deg270
        default:
            throw ScanjetError.usage("orientation: 0 | 90 | 180 | 270")
        }
    }
}

/// Scan bed is ~218 mm wide; height follows the paper / selection.
public enum ScanBed {
    public static let widthMM = 218.0
    public static let heightMM = 297.0
}

/// Region on the glass in millimetres from the top-left of the bed.
public struct ScanRegion: Equatable, Sendable {
    public var xMM: Double
    public var yMM: Double
    public var widthMM: Double
    public var heightMM: Double

    public init(xMM: Double, yMM: Double, widthMM: Double, heightMM: Double) {
        self.xMM = xMM
        self.yMM = yMM
        self.widthMM = widthMM
        self.heightMM = heightMM
    }

    public static func paper(_ size: PaperSize) -> ScanRegion {
        let x = max(0, (ScanBed.widthMM - size.widthMM) / 2)
        return ScanRegion(xMM: x, yMM: 0, widthMM: size.widthMM, heightMM: size.heightMM)
    }

    public static var fullBed: ScanRegion {
        ScanRegion(xMM: 0, yMM: 0, widthMM: ScanBed.widthMM, heightMM: ScanBed.heightMM)
    }
}

public struct ScanRequest: Sendable {
    public var kind: ScanKind = .colour
    public var colorDepth: ColorDepth = .millions
    public var dpi: Int = 300
    public var useCustomSize = false
    public var paperSize: PaperSize = .a4
    public var orientation: ScanOrientation = .deg0
    public var region: ScanRegion
    public var outputDirectory: URL
    public var name: String
    public var format: OutputFormat = .tiff
    public var combine = false
    public var imageCorrection = ImageCorrection()
    public var useShading = true
    public var shadingPath: String?
    public var keepRaw = false
    public var gamma: Double?
    public var feed: UInt32?
    public var photo = PhotoSettings()
    /// When set (CLI `-o file`), write exactly this path instead of unique-ifying.
    public var explicitOutputURL: URL?

    public init(
        kind: ScanKind = .colour,
        colorDepth: ColorDepth = .millions,
        dpi: Int = 300,
        useCustomSize: Bool = false,
        paperSize: PaperSize = .a4,
        orientation: ScanOrientation = .deg0,
        region: ScanRegion? = nil,
        outputDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop"),
        name: String = "Scan",
        format: OutputFormat = .tiff,
        combine: Bool = false,
        useShading: Bool = true
    ) {
        self.kind = kind
        self.colorDepth = colorDepth
        self.dpi = dpi
        self.useCustomSize = useCustomSize
        self.paperSize = paperSize
        self.orientation = orientation
        self.region = region ?? ScanRegion.paper(paperSize)
        self.outputDirectory = outputDirectory
        self.name = name
        self.format = format
        self.combine = combine
        self.useShading = useShading
        self.imageCorrection = ImageCorrection()
    }

    public var effectiveRegion: ScanRegion {
        useCustomSize ? region : ScanRegion.paper(paperSize)
    }

    /// Overview always captures the whole glass at 75 dpi, independent of size/kind.
    public func preparedForOverview() -> ScanRequest {
        var overview = self
        overview.dpi = 75
        overview.kind = .colour
        overview.colorDepth = .millions
        overview.format = .tiff
        overview.combine = false
        overview.useCustomSize = true
        overview.region = .fullBed
        overview.orientation = .deg0
        overview.imageCorrection.mode = .none
        return overview
    }

    func withCorrectionDisabled() -> ScanRequest {
        var copy = self
        copy.imageCorrection.mode = .none
        return copy
    }

    public var resolvedColorDepth: ColorDepth {
        if kind == .text { return .millions }
        if !format.supportsBillions { return .millions }
        return colorDepth
    }

    public var capturesColour: Bool {
        switch kind {
        case .colour: return true
        case .photo: return photo.subject.isColour
        case .blackAndWhite, .text: return false
        }
    }

    /// File names for Photo save: `Name.jpg` when there is one frame, `Name-1.jpg`… when several.
    public func photoOutputURLs(count: Int) -> [URL] {
        guard count > 0 else { return [] }
        if count == 1 {
            if let explicitOutputURL { return [explicitOutputURL] }
            return [uniqueURL(outputDirectory.appendingPathComponent(name).appendingPathExtension(format.fileExtension))]
        }
        var urls: [URL] = []
        var n = 1
        while urls.count < count {
            let candidate = outputDirectory
                .appendingPathComponent("\(name)-\(n)")
                .appendingPathExtension(format.fileExtension)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                urls.append(candidate)
            }
            n += 1
        }
        return urls
    }

    public func outputURL(combineExisting: Bool) -> URL {
        if let explicitOutputURL {
            return explicitOutputURL
        }
        let base = outputDirectory.appendingPathComponent(name).appendingPathExtension(format.fileExtension)
        if combine && combineExisting && FileManager.default.fileExists(atPath: base.path) {
            return base
        }
        return uniqueURL(base)
    }

    public func previewScratchURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("scanjet-preview-\(UUID().uuidString).png")
    }

    public func rawScratchURL(near output: URL) -> URL {
        output.deletingPathExtension().appendingPathExtension("raw16")
    }

    public func tempTIFFURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("scanjet-\(UUID().uuidString).tiff")
    }

    private func uniqueURL(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 2
        while true {
            let candidate = url.deletingLastPathComponent()
                .appendingPathComponent("\(stem)-\(n)")
                .appendingPathExtension(ext)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            n += 1
        }
    }
}

public enum ScanRasterEncoding: Sendable {
    case tiff
    case png
    case jpeg
    case bmp
    case gif
    case pdf
    case heic
    case jpeg2000

    init(_ format: OutputFormat) {
        switch format {
        case .tiff: self = .tiff
        case .png: self = .png
        case .jpeg: self = .jpeg
        case .bmp: self = .bmp
        case .gif: self = .gif
        case .pdf: self = .pdf
        case .heic: self = .heic
        case .jpeg2000: self = .jpeg2000
        }
    }

    var format: OutputFormat {
        switch self {
        case .tiff: return .tiff
        case .png: return .png
        case .jpeg: return .jpeg
        case .bmp: return .bmp
        case .gif: return .gif
        case .pdf: return .pdf
        case .heic: return .heic
        case .jpeg2000: return .jpeg2000
        }
    }
}

/// Legacy CLI options mapped onto ScanRequest.
public struct ScanOptions {
    public enum Mode: String {
        case color
        case gray
    }

    public var outputPath = "scan.tiff"
    public var mode: Mode = .color
    public var dpi = 300
    public var heightMM = 297.0
    public var useShading = true
    public var shadingPath: String?
    public var shading: Shading?
    public var keepRaw = false
    public var feed: UInt32?
    public var gamma: Double?
    public var cropXMM: Double = 0
    public var cropYMM: Double = 0
    public var cropWidthMM: Double = ScanBed.widthMM
    public var colorDepth: ColorDepth = .millions
    /// If set, the raw 16-bit dump is named next to this path instead of `outputPath`.
    public var rawBeside: String?
    /// Write PNG from the decoder instead of an uncompressed TIFF, then converting.
    public var rasterEncoding: ScanRasterEncoding = .tiff
    /// Build a small preview while decoding so the GUI does not reopen the full frame.
    public var makePreview = false
    public var thresholdText = false
    public var imageCorrection = ImageCorrection()
    public var appendOutput = false
    /// Decode straight into a 90° (true) or 270° (false) rotated TIFF.
    public var rotate90Clockwise: Bool? = nil

    public var feedLines: UInt32 {
        feed ?? ((try? ScanMode.choose(outputDPI: dpi).mode.feedLines) ?? 543)
    }

    public func shadingURL(for mode: ScanMode) -> URL {
        shadingPath.map { URL(fileURLWithPath: $0) } ?? Shading.defaultURL(for: mode)
    }

    public var rawScratchURL: URL {
        let base = rawBeside ?? outputPath
        return URL(fileURLWithPath: base).deletingPathExtension().appendingPathExtension("raw16")
    }

    public func finishRaw(_ url: URL) throws {
        if keepRaw {
            ScanLogger.print("  raw 16-bit: \(url.path)")
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public static func parse(_ args: [String]) throws -> ScanOptions {
        var options = ScanOptions()
        var i = 0
        while i < args.count {
            let arg = args[i]
            func takeValue() throws -> String {
                i += 1
                guard i < args.count else {
                    throw ScanjetError.usage("\(arg) needs a value")
                }
                return args[i]
            }
            switch arg {
            case "-o", "--output":
                options.outputPath = try takeValue()
            case "--mode":
                let raw = try takeValue()
                guard let mode = Mode(rawValue: raw) else {
                    throw ScanjetError.usage("mode: color|gray")
                }
                options.mode = mode
            case "--dpi":
                let raw = try takeValue()
                guard let value = Int(raw) else {
                    throw ScanjetError.usage("dpi: integer")
                }
                _ = try ScanMode.choose(outputDPI: value)
                options.dpi = value
            case "--height":
                options.heightMM = Double(try takeValue()) ?? 297
            case "--raw":
                options.keepRaw = true
            case "--gamma":
                let raw = try takeValue()
                guard let value = Double(raw), value > 0 else {
                    throw ScanjetError.usage("gamma: positive number (1 is linear)")
                }
                options.gamma = value
            case "--feed":
                options.feed = UInt32(try takeValue())
            case "--shading":
                options.shadingPath = try takeValue()
            case "--no-shading":
                options.useShading = false
            default:
                throw ScanjetError.usage("unknown argument \(arg)")
            }
            i += 1
        }
        return options
    }

    public init() {}
}

extension ScanRequest {
    public func toScanOptions(outputPath: String) throws -> ScanOptions {
        let region = effectiveRegion
        var options = ScanOptions()
        options.outputPath = outputPath
        options.dpi = dpi
        options.heightMM = region.heightMM
        options.useShading = useShading
        options.shadingPath = shadingPath
        options.keepRaw = keepRaw
        options.gamma = gamma
        options.mode = capturesColour ? .color : .gray
        options.cropXMM = region.xMM
        options.cropYMM = region.yMM
        options.cropWidthMM = region.widthMM
        options.colorDepth = resolvedColorDepth
        options.imageCorrection = imageCorrection
        if let feed {
            options.feed = feed
        } else {
            let (mode, _) = try ScanMode.choose(outputDPI: dpi)
            options.feed = mode.feedLines
        }
        return options
    }

    public static func parseCLI(_ args: [String]) throws -> ScanRequest {
        var request = ScanRequest()
        request.outputDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        request.name = "scan"

        var outputArg: String?
        var nameArg: String?
        var formatArg: OutputFormat?
        var kindArg: ScanKind?
        var modeArg: ScanKind?
        var heightArg: Double?
        var dpiWasSet = false

        var i = 0
        while i < args.count {
            let arg = args[i]
            func takeValue() throws -> String {
                i += 1
                guard i < args.count else {
                    throw ScanjetError.usage("\(arg) needs a value")
                }
                return args[i]
            }
            switch arg {
            case "-o", "--output":
                outputArg = try takeValue()
            case "--name":
                nameArg = try takeValue()
            case "--format":
                formatArg = try OutputFormat.parseCLI(try takeValue())
            case "--kind":
                kindArg = try ScanKind.parseCLI(try takeValue())
            case "--mode":
                let raw = try takeValue()
                guard raw == "color" || raw == "gray" else {
                    throw ScanjetError.usage("mode: color|gray")
                }
                modeArg = try ScanKind.parseCLI(raw)
            case "--colours", "--colors", "--depth":
                request.colorDepth = try ColorDepth.parseCLI(try takeValue())
            case "--size":
                request.paperSize = try PaperSize.parseCLI(try takeValue())
            case "--orientation":
                request.orientation = try ScanOrientation.parseCLI(try takeValue())
            case "--combine":
                request.combine = true
            case "--dpi":
                let raw = try takeValue()
                guard let value = Int(raw) else {
                    throw ScanjetError.usage("dpi: integer")
                }
                _ = try ScanMode.choose(outputDPI: value)
                request.dpi = value
                dpiWasSet = true
            case "--photo-subject":
                request.photo.subject = try PhotoSubject.parseCLI(try takeValue())
            case "--photo-layout":
                request.photo.layout = try PhotoLayout.parseCLI(try takeValue())
            case "--photo-format":
                request.photo.filmFormat = try PhotoFilmFormat.parseCLI(try takeValue())
            case "--height":
                let raw = try takeValue()
                guard let value = Double(raw), value > 0 else {
                    throw ScanjetError.usage("height: positive number of millimetres")
                }
                heightArg = value
            case "--raw":
                request.keepRaw = true
            case "--gamma":
                let raw = try takeValue()
                guard let value = Double(raw), value > 0 else {
                    throw ScanjetError.usage("gamma: positive number (1 is linear)")
                }
                request.gamma = value
            case "--feed":
                let raw = try takeValue()
                guard let value = UInt32(raw) else {
                    throw ScanjetError.usage("feed: integer")
                }
                request.feed = value
            case "--shading":
                request.shadingPath = try takeValue()
            case "--no-shading":
                request.useShading = false
            default:
                throw ScanjetError.usage("unknown argument \(arg)")
            }
            i += 1
        }

        if let kindArg {
            request.kind = kindArg
        } else if let modeArg {
            request.kind = modeArg
        }

        if request.kind == .photo {
            if formatArg == nil && outputArg == nil {
                request.format = .jpeg
            }
            if !dpiWasSet {
                request.dpi = request.photo.subject.defaultDPI
            }
        }

        if let heightArg {
            request.useCustomSize = true
            let paper = ScanRegion.paper(request.paperSize)
            request.region = ScanRegion(xMM: paper.xMM, yMM: paper.yMM,
                                        widthMM: paper.widthMM, heightMM: heightArg)
        }

        if let formatArg {
            request.format = formatArg
        }
        if let nameArg {
            request.name = nameArg
        }

        if let outputArg {
            let url = URL(fileURLWithPath: outputArg)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                request.outputDirectory = url
            } else {
                let dir = url.deletingLastPathComponent()
                request.outputDirectory = dir.path.isEmpty
                    ? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    : dir
                let ext = url.pathExtension
                let stem = url.deletingPathExtension().lastPathComponent
                if nameArg == nil, !stem.isEmpty {
                    request.name = stem
                }
                if !ext.isEmpty {
                    guard let inferred = OutputFormat.fromFileExtension(ext) else {
                        throw ScanjetError.usage("unknown output extension .\(ext)")
                    }
                    if let formatArg, formatArg != inferred {
                        throw ScanjetError.usage(
                            "-o extension (.\(ext)) does not match --format \(formatArg.rawValue)"
                        )
                    }
                    if formatArg == nil {
                        request.format = inferred
                    }
                }
                request.explicitOutputURL = request.outputDirectory
                    .appendingPathComponent(request.name)
                    .appendingPathExtension(request.format.fileExtension)
            }
        }

        if request.kind == .photo && request.combine {
            throw ScanjetError.usage("combine is not available for photo")
        }
        if request.combine && !request.format.supportsCombine {
            throw ScanjetError.usage("combine is only supported for PDF and TIFF")
        }
        if request.colorDepth == .billions {
            if request.kind == .text {
                throw ScanjetError.usage("billions is not available for text")
            }
            if !request.format.supportsBillions {
                throw ScanjetError.usage("billions is only available for TIFF and PNG")
            }
        }

        return request
    }
}
