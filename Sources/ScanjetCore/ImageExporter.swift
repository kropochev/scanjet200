import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import PDFKit

public enum ImageExporter {
    public static func export(sourceTIFF: URL, request: ScanRequest, outputURL: URL) throws {
        let append = request.combine && request.format.supportsCombine
            && FileManager.default.fileExists(atPath: outputURL.path)

        if canPassThrough(request, append: append) {
            try moveTIFF(sourceTIFF, to: outputURL)
            return
        }
        if TIFFPreview.info(of: sourceTIFF) != nil {
            try StreamExport.write(fromTIFF: sourceTIFF, request: request, output: outputURL, append: append)
            return
        }

        try autoreleasepool {
            let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
            guard let source = CGImageSourceCreateWithURL(sourceTIFF as CFURL, options as CFDictionary) else {
                throw ScanjetError.io("cannot read intermediate TIFF")
            }
            guard let loaded = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) else {
                throw ScanjetError.io("empty intermediate TIFF")
            }
            let image = try postProcess(loaded, request: request)
            switch request.format {
            case .pdf:
                try writePDF(image, to: outputURL, append: append)
            case .tiff:
                try writeRaster(image, to: outputURL, format: request.format, append: append, dpi: request.dpi)
            default:
                if append {
                    throw ScanjetError.io("combine is only supported for PDF and TIFF")
                }
                try writeRaster(image, to: outputURL, format: request.format, append: false, dpi: request.dpi)
            }
        }
    }

    /// Uncompressed TIFF from `TIFFWriter` needs no second decode when Kind is not Text.
    static func canPassThrough(_ request: ScanRequest, append: Bool) -> Bool {
        request.format == .tiff
            && request.kind != .text
            && request.orientation == .deg0
            && !request.imageCorrection.shouldApply
            && !append
    }

    /// Colour/gray PNG can be written row by row from our TIFF — ImageIO would load the whole frame.
    static func canStreamPNG(_ request: ScanRequest, append: Bool) -> Bool {
        request.format == .png
            && request.kind != .text
            && request.orientation == .deg0
            && !request.imageCorrection.shouldApply
            && !append
    }

    private static func moveTIFF(_ source: URL, to output: URL) throws {
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if source.standardizedFileURL == output.standardizedFileURL {
            return
        }
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        try FileManager.default.moveItem(at: source, to: output)
    }

    public static func makePreviewPNG(from tiff: URL, request: ScanRequest? = nil,
                                      maxDimension: Int = 1600) throws -> URL {
        if let sampled = try TIFFPreview.subsampledImage(from: tiff, maxDimension: maxDimension) {
            let image = try postProcessIfNeeded(sampled, request: request)
            return try writePreviewPNG(image)
        }
        guard let source = CGImageSourceCreateWithURL(tiff as CFURL, nil) else {
            throw ScanjetError.io("cannot load preview")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceShouldCache: false
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ScanjetError.io("cannot load preview")
        }
        let image = try postProcessIfNeeded(thumbnail, request: request)
        return try writePreviewPNG(image)
    }

    private static func postProcessIfNeeded(_ image: CGImage, request: ScanRequest?) throws -> CGImage {
        guard let request else { return image }
        return try postProcess(image, request: request)
    }

    public static func makePreviewPNG(from image: CGImage, maxDimension: Int = 1600) throws -> URL {
        let scale = min(1.0, Double(maxDimension) / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width) * scale))
        let h = max(1, Int(Double(image.height) * scale))
        return try writePreviewPNG(image, width: w, height: h)
    }

    private static func writePreviewPNG(_ image: CGImage, width: Int? = nil, height: Int? = nil) throws -> URL {
        let w = width ?? image.width
        let h = height ?? image.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ScanjetError.io("preview context failed")
        }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage() else {
            throw ScanjetError.io("preview render failed")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scanjet-preview-\(UUID().uuidString).png")
        try writeRaster(scaled, to: url, format: .png, append: false, dpi: 75)
        return url
    }

    static func finalizePreview(_ url: URL?, request: ScanRequest) throws -> URL? {
        guard let url else { return nil }
        if request.orientation == .deg0 && request.kind != .text {
            return url
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return url
        }
        let processed = try postProcess(image, request: request)
        try? FileManager.default.removeItem(at: url)
        return try writePreviewPNG(processed)
    }

    private static func postProcess(_ image: CGImage, request: ScanRequest) throws -> CGImage {
        var current = image
        if request.orientation != .deg0 {
            current = rotate(current, degrees: request.orientation.rawValue)
        }
        if request.imageCorrection.shouldApply {
            current = request.imageCorrection.applying(to: current)
        }
        switch request.kind {
        case .colour:
            break
        case .blackAndWhite:
            current = toGrayscale(current)
        case .text:
            current = threshold(current)
        }
        return current
    }

    private static func bitmapInfo(for image: CGImage, alpha: CGImageAlphaInfo) -> CGBitmapInfo {
        if image.bitsPerComponent == 16 {
            return CGBitmapInfo(rawValue: alpha.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
        }
        return CGBitmapInfo(rawValue: alpha.rawValue)
    }

    private static func rotate(_ image: CGImage, degrees: Int) -> CGImage {
        let radians = CGFloat(degrees) * .pi / 180
        let w = image.width
        let h = image.height
        let swap = degrees == 90 || degrees == 270
        let cw = swap ? h : w
        let ch = swap ? w : h
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bpc = image.bitsPerComponent
        let alpha: CGImageAlphaInfo = image.colorSpace?.numberOfComponents == 1 ? .none : .noneSkipLast
        guard let ctx = CGContext(data: nil, width: cw, height: ch, bitsPerComponent: bpc,
                                  bytesPerRow: 0, space: colorSpace,
                                  bitmapInfo: bitmapInfo(for: image, alpha: alpha).rawValue) else {
            return image
        }
        ctx.translateBy(x: CGFloat(cw) / 2, y: CGFloat(ch) / 2)
        ctx.rotate(by: radians)
        ctx.draw(image, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2, width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage() ?? image
    }

    private static func toGrayscale(_ image: CGImage) -> CGImage {
        let bpc = image.bitsPerComponent
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height,
                                  bitsPerComponent: bpc, bytesPerRow: 0, space: colorSpace,
                                  bitmapInfo: bitmapInfo(for: image, alpha: .none).rawValue) else {
            return image
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    private static func threshold(_ image: CGImage, cutoff: UInt8 = 180) -> CGImage {
        let gray = toGrayscale(image)
        let w = gray.width
        let h = gray.height
        guard let provider = gray.dataProvider, let data = provider.data else { return gray }
        let src = CFDataGetBytePtr(data)!
        let bytesPerRow = gray.bytesPerRow
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let v = src[y * bytesPerRow + x]
                out[y * w + x] = v >= cutoff ? 255 : 0
            }
        }
        let cs = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: &out, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w, space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let result = ctx.makeImage() else {
            return gray
        }
        return result
    }

    private static func writeRaster(_ image: CGImage, to url: URL, format: OutputFormat,
                                    append: Bool, dpi: Int) throws {
        let type = try format.imageIOType()
        if append && format == .tiff {
            try appendTIFF(image, to: url, dpi: dpi)
            return
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw ScanjetError.io("cannot write \(format.rawValue) to \(url.path)")
        }
        let props: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ScanjetError.io("failed to write \(url.path)")
        }
    }

    private static func appendTIFF(_ image: CGImage, to url: URL, dpi: Int) throws {
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".scanjet-append-\(UUID().uuidString).tiff")
        defer { try? FileManager.default.removeItem(at: tmp) }

        if FileManager.default.fileExists(atPath: url.path),
           let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
            let count = CGImageSourceGetCount(src)
            guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, UTType.tiff.identifier as CFString,
                                                               count + 1, nil) else {
                throw ScanjetError.io("cannot open TIFF for append")
            }
            for i in 0..<count {
                if let page = CGImageSourceCreateImageAtIndex(src, i, nil) {
                    CGImageDestinationAddImage(dest, page, nil)
                }
            }
            let props: [CFString: Any] = [
                kCGImagePropertyDPIWidth: dpi,
                kCGImagePropertyDPIHeight: dpi
            ]
            CGImageDestinationAddImage(dest, image, props as CFDictionary)
            guard CGImageDestinationFinalize(dest) else {
                throw ScanjetError.io("TIFF append failed")
            }
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try writeRaster(image, to: url, format: .tiff, append: false, dpi: dpi)
        }
    }

    private static func writePDF(_ image: CGImage, to url: URL, append: Bool) throws {
        let pageRect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        if append, FileManager.default.fileExists(atPath: url.path),
           let doc = PDFDocument(url: url) {
            let page = PDFPage(image: NSImage(cgImage: image, size: pageRect.size))!
            doc.insert(page, at: doc.pageCount)
            guard doc.write(to: url) else {
                throw ScanjetError.io("PDF append failed")
            }
            return
        }
        let doc = PDFDocument()
        doc.insert(PDFPage(image: NSImage(cgImage: image, size: pageRect.size))!, at: 0)
        guard doc.write(to: url) else {
            throw ScanjetError.io("PDF write failed")
        }
    }
}
