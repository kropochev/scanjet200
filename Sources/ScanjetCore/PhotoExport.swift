import Foundation
import CoreGraphics
import ImageIO

public enum PhotoExport {
    public static func save(
        captureURL: URL,
        frames: [PhotoFrame],
        capture: ScanRegion,
        request: ScanRequest
    ) throws -> [URL] {
        let ordered = PhotoGeometry.sorted(frames)
        let working = ordered.isEmpty ? [PhotoFrame(region: capture)] : ordered
        let urls = request.photoOutputURLs(count: working.count)
        guard urls.count == working.count else {
            throw ScanjetError.io("could not allocate photo file names")
        }

        let source = try loadImage(captureURL)
        try FileManager.default.createDirectory(
            at: request.outputDirectory, withIntermediateDirectories: true
        )

        for (index, frame) in working.enumerated() {
            var image = try crop(source, frame: frame, capture: capture, settings: request.photo)
            if request.photo.subject.isColour == false {
                image = ImageExporter.toGrayscale(image)
            }
            if request.imageCorrection.shouldApply {
                image = request.imageCorrection.applying(to: image)
            }
            switch request.orientation {
            case .deg0:
                break
            default:
                image = ImageExporter.rotate(image, degrees: request.orientation.rawValue)
            }
            try ImageExporter.writeRaster(
                image, to: urls[index], format: request.format, append: false, dpi: request.dpi
            )
        }
        return urls
    }

    public static func processedPreview(_ image: CGImage, request: ScanRequest) -> CGImage {
        var current = image
        if request.photo.effectiveInvert || request.photo.effectiveOrangeMask || request.photo.effectiveAutoLevels {
            current = NegativeConvert.applying(current, settings: request.photo)
        }
        if request.imageCorrection.shouldApply {
            current = request.imageCorrection.applying(to: current)
        }
        return current
    }

    private static func crop(
        _ image: CGImage,
        frame: PhotoFrame,
        capture: ScanRegion,
        settings: PhotoSettings
    ) throws -> CGImage {
        let region = frame.region.inset(byMM: settings.effectiveMarginMM).clamped(to: capture)
        var pixel = PhotoGeometry.pixelRect(
            for: region, capture: capture, imageWidth: image.width, imageHeight: image.height
        )
        pixel = pixel.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard pixel.width >= 1, pixel.height >= 1 else {
            throw ScanjetError.io("photo frame is empty")
        }
        guard let croppedBitmap = PhotoBitmap.rgba8(from: image).cropped(to: pixel),
              var cropped = croppedBitmap.makeImage() else {
            throw ScanjetError.io("cannot crop photo frame")
        }
        if settings.straighten, abs(frame.angleDegrees) > 0.4 {
            cropped = ImageExporter.rotate(cropped, degrees: -frame.angleDegrees)
        }
        if frame.extraRotation != .deg0 {
            cropped = ImageExporter.rotate(cropped, degrees: frame.extraRotation.rawValue)
        }
        if settings.effectiveInvert || settings.effectiveOrangeMask || settings.effectiveAutoLevels {
            cropped = NegativeConvert.applying(cropped, settings: settings)
        }
        return cropped
    }

    private static func loadImage(_ url: URL) throws -> CGImage {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) else {
            throw ScanjetError.io("cannot read photo capture")
        }
        return image
    }
}

extension ImageExporter {
    static func rotate(_ image: CGImage, degrees: Double) -> CGImage {
        let snapped = Int(degrees.rounded())
        if snapped % 90 == 0 {
            return rotate(image, degrees: ((snapped % 360) + 360) % 360)
        }
        let radians = CGFloat(degrees) * .pi / 180
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let bounds = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
            .applying(CGAffineTransform(rotationAngle: radians))
        let cw = max(1, Int(ceil(bounds.width)))
        let ch = max(1, Int(ceil(bounds.height)))
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bpc = image.bitsPerComponent
        let alpha: CGImageAlphaInfo = image.colorSpace?.numberOfComponents == 1 ? .none : .noneSkipLast
        guard let ctx = CGContext(
            data: nil, width: cw, height: ch, bitsPerComponent: bpc,
            bytesPerRow: 0, space: colorSpace,
            bitmapInfo: bitmapInfo(for: image, alpha: alpha).rawValue
        ) else {
            return image
        }
        ctx.translateBy(x: CGFloat(cw) / 2, y: CGFloat(ch) / 2)
        ctx.rotate(by: radians)
        ctx.draw(image, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        return ctx.makeImage() ?? image
    }
}
