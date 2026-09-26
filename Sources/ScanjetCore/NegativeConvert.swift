import Foundation
import CoreGraphics

public enum NegativeConvert {
    /// Invert a reflective film scan toward a positive. Quality is limited without a backlight.
    public static func applying(_ image: CGImage, settings: PhotoSettings) -> CGImage {
        guard settings.effectiveInvert || settings.effectiveOrangeMask || settings.effectiveAutoLevels else {
            return image
        }
        var bitmap = PhotoBitmap.rgba8(from: image)
        if settings.effectiveOrangeMask {
            applyOrangeMask(&bitmap.pixels, width: bitmap.width, height: bitmap.height)
        }
        if settings.effectiveInvert {
            invertRGB(&bitmap.pixels)
        }
        if settings.effectiveAutoLevels {
            stretchLevels(&bitmap.pixels, width: bitmap.width, height: bitmap.height)
        }
        return bitmap.makeImage() ?? image
    }

    public static func meanLuminance(_ image: CGImage) -> Double {
        let bitmap = PhotoBitmap.rgba8(from: image)
        guard bitmap.width > 0, bitmap.height > 0 else { return 0 }
        var sum = 0.0
        let count = bitmap.width * bitmap.height
        for i in 0..<count {
            let o = i * 4
            sum += 0.2126 * Double(bitmap.pixels[o])
                + 0.7152 * Double(bitmap.pixels[o + 1])
                + 0.0722 * Double(bitmap.pixels[o + 2])
        }
        return sum / Double(count)
    }

    private static func invertRGB(_ pixels: inout [UInt8]) {
        var i = 0
        while i + 3 < pixels.count {
            pixels[i] = 255 - pixels[i]
            pixels[i + 1] = 255 - pixels[i + 1]
            pixels[i + 2] = 255 - pixels[i + 2]
            i += 4
        }
    }

    /// Divide by a high-percentile estimate of the unexposed film base sampled on the border.
    private static func applyOrangeMask(_ pixels: inout [UInt8], width: Int, height: Int) {
        let border = max(2, min(width, height) / 30)
        var rVals: [UInt8] = []
        var gVals: [UInt8] = []
        var bVals: [UInt8] = []
        rVals.reserveCapacity((width + height) * border)
        for y in 0..<height {
            for x in 0..<width {
                if x >= border && x < width - border && y >= border && y < height - border {
                    continue
                }
                let o = (y * width + x) * 4
                rVals.append(pixels[o])
                gVals.append(pixels[o + 1])
                bVals.append(pixels[o + 2])
            }
        }
        guard !rVals.isEmpty else { return }
        let baseR = max(1, Int(percentile(rVals, 0.90)))
        let baseG = max(1, Int(percentile(gVals, 0.90)))
        let baseB = max(1, Int(percentile(bVals, 0.90)))
        var i = 0
        while i + 3 < pixels.count {
            pixels[i] = UInt8(min(255, Int(pixels[i]) * 255 / baseR))
            pixels[i + 1] = UInt8(min(255, Int(pixels[i + 1]) * 255 / baseG))
            pixels[i + 2] = UInt8(min(255, Int(pixels[i + 2]) * 255 / baseB))
            i += 4
        }
    }

    private static func stretchLevels(_ pixels: inout [UInt8], width: Int, height: Int) {
        var hist = [[Int](repeating: 0, count: 256), [Int](repeating: 0, count: 256), [Int](repeating: 0, count: 256)]
        let count = width * height
        for i in 0..<count {
            let o = i * 4
            hist[0][Int(pixels[o])] += 1
            hist[1][Int(pixels[o + 1])] += 1
            hist[2][Int(pixels[o + 2])] += 1
        }
        let lutR = stretchLUT(hist[0], total: count)
        let lutG = stretchLUT(hist[1], total: count)
        let lutB = stretchLUT(hist[2], total: count)
        var i = 0
        while i + 3 < pixels.count {
            pixels[i] = lutR[Int(pixels[i])]
            pixels[i + 1] = lutG[Int(pixels[i + 1])]
            pixels[i + 2] = lutB[Int(pixels[i + 2])]
            i += 4
        }
    }

    private static func stretchLUT(_ hist: [Int], total: Int) -> [UInt8] {
        let loCount = max(1, Int(Double(total) * 0.01))
        let hiCount = max(1, Int(Double(total) * 0.99))
        var lo = 0
        var hi = 255
        var seen = 0
        for v in 0..<256 {
            seen += hist[v]
            if seen >= loCount {
                lo = v
                break
            }
        }
        seen = 0
        for v in 0..<256 {
            seen += hist[v]
            if seen >= hiCount {
                hi = v
                break
            }
        }
        if hi <= lo {
            return (0..<256).map { UInt8($0) }
        }
        let span = Double(hi - lo)
        return (0..<256).map { v in
            let t = min(1, max(0, Double(v - lo) / span))
            return UInt8((t * 255).rounded())
        }
    }

    private static func percentile(_ values: [UInt8], _ p: Double) -> UInt8 {
        let sorted = values.sorted()
        let idx = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
        return sorted[idx]
    }
}

struct PhotoBitmap {
    var pixels: [UInt8]
    var width: Int
    var height: Int

    static func rgba8(from image: CGImage) -> PhotoBitmap {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: max(1, width * height * 4))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(
                    data: base, width: max(1, width), height: max(1, height), bitsPerComponent: 8,
                    bytesPerRow: max(1, width) * 4, space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return PhotoBitmap(pixels: pixels, width: width, height: height)
    }

    func cropped(to rect: CGRect) -> PhotoBitmap? {
        let x0 = max(0, Int(rect.minX.rounded(.down)))
        let y0 = max(0, Int(rect.minY.rounded(.down)))
        let x1 = min(width, Int(rect.maxX.rounded(.up)))
        let y1 = min(height, Int(rect.maxY.rounded(.up)))
        let w = x1 - x0
        let h = y1 - y0
        guard w >= 1, h >= 1 else { return nil }
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            let src = ((y0 + y) * width + x0) * 4
            let dst = y * w * 4
            out.replaceSubrange(dst..<(dst + w * 4), with: pixels[src..<(src + w * 4)])
        }
        return PhotoBitmap(pixels: out, width: w, height: h)
    }

    func makeImage() -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: max(1, width), height: max(1, height), bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let dest = ctx.data else { return nil }
        let bpr = ctx.bytesPerRow
        let out = dest.bindMemory(to: UInt8.self, capacity: bpr * height)
        for y in 0..<height {
            for x in 0..<width {
                let s = (y * width + x) * 4
                let d = y * bpr + x * 4
                out[d] = pixels[s]
                out[d + 1] = pixels[s + 1]
                out[d + 2] = pixels[s + 2]
                out[d + 3] = pixels[s + 3]
            }
        }
        return ctx.makeImage()
    }
}
