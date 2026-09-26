import Foundation
import ImageIO
import CoreGraphics

public struct ScanResult: Sendable {
    public var outputURL: URL
    public var width: Int
    public var height: Int
    public var previewURL: URL?
    public var outputURLs: [URL]

    public init(outputURL: URL, width: Int, height: Int, previewURL: URL? = nil, outputURLs: [URL]? = nil) {
        self.outputURL = outputURL
        self.width = width
        self.height = height
        self.previewURL = previewURL
        self.outputURLs = outputURLs ?? [outputURL]
    }
}

public enum ScanService {
    public static func overview(request: ScanRequest, progress: ScanProgressHandler? = nil,
                                cancel: ScanCancel? = nil) throws -> ScanResult {
        try withLogger(progress) {
            try autoreleasepool {
                try cancel?.throwIfRequested()
                let overview = request.preparedForOverview()
                let temp = overview.tempTIFFURL()
                var removeTemp = true
                defer {
                    if removeTemp { try? FileManager.default.removeItem(at: temp) }
                }
                let result = try performScan(overview, outputPath: temp.path, cancel: cancel)
                try cancel?.throwIfRequested()
                let preview = try ImageExporter.makePreviewPNG(from: temp)
                try? FileManager.default.removeItem(at: temp)
                removeTemp = false
                ProcessMemory.releaseToOS()
                return ScanResult(outputURL: preview, width: result.width, height: result.height, previewURL: preview)
            }
        }
    }

    public static func scan(request: ScanRequest, progress: ScanProgressHandler? = nil,
                            cancel: ScanCancel? = nil) throws -> ScanResult {
        if request.kind == .photo {
            return try scanPhotoAndSave(request: request, progress: progress, cancel: cancel)
        }
        return try withLogger(progress) {
            try autoreleasepool {
                try cancel?.throwIfRequested()
                let combineExisting = request.combine && request.format.supportsCombine
                    && FileManager.default.fileExists(atPath: request.outputURL(combineExisting: true).path)
                let outputURL = request.outputURL(combineExisting: combineExisting)
                let rotateCW: Bool? = {
                    switch request.orientation {
                    case .deg90: return true
                    case .deg270: return false
                    default: return nil
                    }
                }()
                let direct = request.orientation == .deg0
                    && !(combineExisting && request.format == .tiff)

                if direct {
                    let captured = try performScan(
                        request, outputPath: outputURL.path,
                        rawBeside: request.keepRaw ? outputURL.path : nil,
                        cancel: cancel,
                        encoding: ScanRasterEncoding(request.format),
                        makePreview: true,
                        thresholdText: request.kind == .text,
                        append: combineExisting && request.format == .pdf
                    )
                    ScanLogger.log(.done, 1, outputURL.path)
                    ProcessMemory.releaseToOS()
                    let preview = try ImageExporter.finalizePreview(
                        captured.previewURL, request: request.withCorrectionDisabled()
                    )
                    return ScanResult(outputURL: outputURL, width: captured.width, height: captured.height,
                                      previewURL: preview)
                }

                let temp = request.tempTIFFURL()
                var removeTemp = true
                defer {
                    if removeTemp { try? FileManager.default.removeItem(at: temp) }
                }
                let writeFinalTIFF = rotateCW != nil
                    && request.format == .tiff && request.kind != .text && !combineExisting
                let scanURL = writeFinalTIFF ? outputURL : temp
                let captured = try performScan(
                    request, outputPath: scanURL.path,
                    rawBeside: request.keepRaw ? outputURL.path : nil,
                    cancel: cancel, makePreview: true, thresholdText: false,
                    rotate90Clockwise: rotateCW
                )
                try cancel?.throwIfRequested()
                if !writeFinalTIFF {
                    ScanLogger.log(.exporting, 0, "writing \(outputURL.lastPathComponent)")
                    var export = request.withCorrectionDisabled()
                    if rotateCW != nil {
                        export.orientation = .deg0
                    }
                    try StreamExport.write(fromTIFF: scanURL, request: export, output: outputURL,
                                           append: combineExisting)
                    if scanURL != outputURL {
                        try? FileManager.default.removeItem(at: scanURL)
                    }
                }
                removeTemp = false
                ScanLogger.log(.done, 1, outputURL.path)
                ProcessMemory.releaseToOS()
                let preview = try ImageExporter.finalizePreview(
                    captured.previewURL, request: request.withCorrectionDisabled()
                )
                return ScanResult(outputURL: outputURL, width: captured.width, height: captured.height,
                                  previewURL: preview)
            }
        }
    }

    public static func calibrate(dpi: Int, progress: ScanProgressHandler? = nil,
                                 cancel: ScanCancel? = nil) throws -> URL {
        try withLogger(progress) {
            try cancel?.throwIfRequested()
            var request = ScanRequest(dpi: dpi, useShading: false)
            request.region = ScanRegion.paper(.a4)
            let temp = request.tempTIFFURL()
            defer { try? FileManager.default.removeItem(at: temp) }

            var options = try request.toScanOptions(outputPath: temp.path)
            options.useShading = false
            options.keepRaw = false
            let (mode, _) = try ScanMode.choose(outputDPI: dpi)

            var shading: Shading!
            try DeviceSession.withOpenDevice { device in
                shading = try ScanEngine(device: device, progress: ScanLogger.handler, cancel: cancel)
                    .calibrate(options: options)
            }

            try cancel?.throwIfRequested()
            let url = Shading.defaultURL(for: mode)
            try shading.save(to: url)
            ProcessMemory.releaseToOS()
            return url
        }
    }

    /// Capture into a temp TIFF, detect frames, do not write final files. GUI review uses this.
    public static func capturePhoto(request: ScanRequest, progress: ScanProgressHandler? = nil,
                                    cancel: ScanCancel? = nil) throws -> PhotoReviewSession {
        try withLogger(progress) {
            try autoreleasepool {
                try cancel?.throwIfRequested()
                var capture = request
                capture.orientation = .deg0
                capture.format = .tiff
                capture.combine = false
                let temp = request.tempTIFFURL()
                let captured = try performScan(
                    capture, outputPath: temp.path,
                    rawBeside: request.keepRaw ? request.outputURL(combineExisting: false).path : nil,
                    cancel: cancel,
                    encoding: .tiff,
                    makePreview: true
                )
                try cancel?.throwIfRequested()
                ScanLogger.log(.exporting, 0, "finding photos")
                let detectImage: CGImage
                if let preview = captured.previewURL,
                   let source = CGImageSourceCreateWithURL(preview as CFURL, nil),
                   let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                    detectImage = image
                } else if let sampled = try TIFFPreview.subsampledImage(from: temp, maxDimension: 1600) {
                    detectImage = sampled
                } else {
                    throw ScanjetError.io("cannot build a preview for photo detection")
                }
                let region = request.effectiveRegion
                let detected = PhotoDetector.detect(
                    image: detectImage, capture: region, settings: request.photo
                )
                ProcessMemory.releaseToOS()
                return PhotoReviewSession(
                    captureURL: temp,
                    previewURL: captured.previewURL,
                    region: region,
                    dpi: request.dpi,
                    width: captured.width,
                    height: captured.height,
                    frames: detected.frames,
                    stripBounds: detected.stripBounds,
                    detectedFilmFormat: detected.filmFormat
                )
            }
        }
    }

    public static func savePhotoSession(_ session: PhotoReviewSession,
                                        request: ScanRequest) throws -> ScanResult {
        ScanLogger.log(.exporting, 0, "writing photos")
        let urls = try PhotoExport.save(
            captureURL: session.captureURL,
            frames: session.frames,
            capture: session.region,
            request: request
        )
        session.removeTemporaryFiles()
        let preview: URL?
        if let last = urls.last {
            preview = try? ImageExporter.makePreviewPNG(from: last, request: nil)
        } else {
            preview = nil
        }
        ScanLogger.log(.done, 1, urls.last?.path ?? "")
        ProcessMemory.releaseToOS()
        let first = urls.first ?? request.outputURL(combineExisting: false)
        return ScanResult(
            outputURL: first,
            width: session.width,
            height: session.height,
            previewURL: preview,
            outputURLs: urls
        )
    }

    private static func scanPhotoAndSave(request: ScanRequest, progress: ScanProgressHandler? = nil,
                                         cancel: ScanCancel? = nil) throws -> ScanResult {
        let session = try capturePhoto(request: request, progress: progress, cancel: cancel)
        do {
            return try savePhotoSession(session, request: request)
        } catch {
            session.removeTemporaryFiles()
            throw error
        }
    }

    @discardableResult
    private static func performScan(_ request: ScanRequest, outputPath: String,
                                    rawBeside: String? = nil,
                                    cancel: ScanCancel? = nil,
                                    encoding: ScanRasterEncoding = .tiff,
                                    makePreview: Bool = false,
                                    thresholdText: Bool = false,
                                    append: Bool = false,
                                    rotate90Clockwise: Bool? = nil) throws -> ScannedImage {
        var options = try request.toScanOptions(outputPath: outputPath)
        options.rawBeside = rawBeside
        options.rasterEncoding = encoding
        options.makePreview = makePreview
        options.thresholdText = thresholdText
        options.appendOutput = append
        options.rotate90Clockwise = rotate90Clockwise
        if !request.capturesColour {
            options.mode = .gray
        }

        let (mode, _) = try ScanMode.choose(outputDPI: request.dpi)
        if request.useShading {
            let url = options.shadingURL(for: mode)
            options.shading = Shading.load(from: url)
        }

        var image: ScannedImage!
        try DeviceSession.withOpenDevice { device in
            let engine = ScanEngine(device: device, progress: ScanLogger.handler, cancel: cancel)
            image = try engine.scan(options: options)
            try options.finishRaw(image.rawURL)
        }
        return image
    }

    private static func withLogger<T>(_ progress: ScanProgressHandler?, _ body: () throws -> T) throws -> T {
        let previous = ScanLogger.handler
        if let progress {
            ScanLogger.handler = progress
        }
        defer { ScanLogger.handler = previous }
        return try body()
    }
}
